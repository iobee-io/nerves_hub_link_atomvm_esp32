defmodule SmartKioskEx do
  @moduledoc """
  A NervesHub device written in Elixir, running on AtomVM.

  The agent itself is `nerves_hub_link_atomvm_esp32`, which is Erlang — so this
  is also the test of whether that library is usable from Elixir without
  anything in between.
  """

  def start do
    config = Config.get()

    # Nothing starts logger_manager on AtomVM, and handlers can only be given
    # to it here: there is no add_handler/3, so the NervesHub handler has to be
    # in place before the agent exists. It finds the agent by registered name.
    #
    # nh_console_h rather than logger_std_h because capture_io is on below.
    # logger runs handlers in the process that logged, so logger_std_h's own
    # io:format would be captured and every line would go up twice.
    {:ok, _logger} =
      :logger_manager.start_link(%{
        log_level: :info,
        logger: [
          :nh_console_h.handler(%{level: :info}),
          :nh_logger.handler(%{level: :info})
        ]
      })

    IO.puts("\n=== smart_kiosk_ex ===")
    IO.puts("AtomVM:         #{inspect(:nh_metadata.atomvm_version())}")
    IO.puts("boot partition: #{inspect(:nh_flash.boot_partition())}")

    report_firmware()

    :ok = start_network(config.sta)
    IO.puts("clock:          #{:erlang.system_time(:second)}")

    url = config.url
    IO.puts("Connecting to #{url}")

    {:ok, agent} =
      :nerves_hub_link.start(%{
        url: url,
        identifier: config.identifier,
        shared_secret: config.shared_secret,
        verify: :none,
        console: true,
        extensions: [:health, :geo, :logging],
        firmware_keys: config.firmware_keys,
        request_firmware_keys: true,
        register: :nerves_hub_link,
        # Everything this process prints from here on also goes to NervesHub,
        # and so does everything the processes it spawns print.
        capture_io: true
      })

    loop(agent, config)
  end

  defp report_firmware do
    case :nh_flash.read_metadata() do
      {:ok, metadata} ->
        IO.puts("app:            #{metadata.app_name} #{metadata.app_version}")
        IO.puts("avm sha256:     #{metadata.avm_sha256}")

      {:error, reason} ->
        IO.puts("firmware unreadable: #{inspect(reason)}")
    end
  end

  defp start_network(sta_config) do
    self_pid = self()

    config = [
      {:sta,
       [
         {:connected, fn -> send(self_pid, :wifi_connected) end},
         {:got_ip, fn ip_info -> send(self_pid, {:wifi_ip, ip_info}) end},
         {:disconnected, fn -> send(self_pid, :wifi_disconnected) end}
         | sta_config
       ]},
      {:sntp,
       [
         {:host, ~c"pool.ntp.org"},
         {:synchronized, fn time -> send(self_pid, {:sntp, time}) end}
       ]}
    ]

    {:ok, _pid} = :network.start(config)

    :ok = await(:wifi_ip, 30_000)
    :ok = await(:sntp, 30_000)
  end

  defp await(what, timeout) do
    receive do
      {^what, value} ->
        IO.puts("#{what}: #{inspect(value)}")
        :ok

      _other ->
        await(what, timeout)
    after
      timeout -> throw({:network_timeout, what})
    end
  end

  defp loop(agent, config) do
    receive do
      {:nerves_hub, {:joined, reply}} ->
        IO.puts("JOINED: #{inspect(reply)}")
        loop(agent, config)

      {:nerves_hub, {:extensions_attached, attached}} ->
        IO.puts("EXTENSIONS: #{inspect(attached)}")

        # Straight through :logger now, with no reference to NervesHub at the
        # call site. Elixir has no Logger on AtomVM, so this is how Elixir code
        # logs here.
        # Charlists and reports only. AtomVM's logger raises badarg on a
        # binary message, which is the obvious thing to write in Elixir.
        :logger.info(~c"smart_kiosk_ex is up")
        :logger.warning(~c"a warning, so levels are visible")
        :logger.info(~c"formatted: ~s and ~p", [~c"a string", 42])
        :logger.error(%{event: :bench, detail: ~c"a report"})

        # And these go up without touching :logger at all -- IO.puts is what
        # most AtomVM code actually uses, binaries and all.
        IO.puts("captured: a plain IO.puts")
        IO.inspect(%{captured: true, from: :io_inspect})
        IO.puts("captured: two lines\nin one write")

        # Spawned after the capture was attached, so it inherits it.
        spawn(fn -> IO.puts("captured: from a spawned process") end)

        loop(agent, config)

      {:nerves_hub, {:identify}} ->
        IO.puts("\n*** IDENTIFY ***\n")
        spawn(fn -> blink(Map.get(config, :led_pin, 2)) end)
        loop(agent, config)

      {:nerves_hub, {:reboot_requested}} ->
        IO.puts("REBOOT requested by NervesHub")
        loop(agent, config)

      {:nerves_hub, {:firmware_keys, count}} ->
        IO.puts("KEYS: #{count} firmware key(s) after the server's")
        loop(agent, config)

      {:nerves_hub, {:console_joined}} ->
        IO.puts("CONSOLE: attached")
        loop(agent, config)

      {:nerves_hub, {:update_ready, slot}} ->
        IO.puts("UPDATE: #{slot} is armed, rebooting")
        :timer.sleep(500)
        :esp.restart()

      {:nerves_hub, {:firmware_committed, slot}} ->
        IO.puts("UPDATE: committed, running #{slot}")
        loop(agent, config)

      {:nerves_hub, event} ->
        IO.puts("nerves_hub: #{inspect(event)}")
        loop(agent, config)

      other ->
        IO.puts("other: #{inspect(other)}")
        loop(agent, config)
    end
  end

  defp blink(pin) do
    :gpio.set_pin_mode(pin, :output)
    blink(pin, 6)
  catch
    class, reason -> IO.puts("identify: no LED on pin #{pin} (#{class}:#{inspect(reason)})")
  end

  defp blink(pin, 0), do: :gpio.digital_write(pin, :low)

  defp blink(pin, remaining) do
    :gpio.digital_write(pin, :high)
    :timer.sleep(150)
    :gpio.digital_write(pin, :low)
    :timer.sleep(150)
    blink(pin, remaining - 1)
  end
end

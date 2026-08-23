defmodule SmartKioskEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :smart_kiosk_ex,
      version: "0.9.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "NervesHub on AtomVM, in Elixir",
      # Runs before every packbeam, so the metadata can never be stale.
      aliases: ["atomvm.packbeam": ["atomvm.application_bin", "atomvm.packbeam"]],
      # ExAtomVM reads these when it builds the packbeam and flashes.
      atomvm: [
        start: SmartKioskEx,
        # main.avm. Must match the table on the device, not this repo's
        # partitions.csv -- see the note there.
        flash_offset: 0x270000
      ]
    ]
  end

  def application do
    [extra_applications: []]
  end

  defp deps do
    [
      {:exatomvm, github: "atomvm/exatomvm", runtime: false},
      # The agent itself, and the transport it drives. Both are rebar3
      # projects, so mix is told which manager to use.
      #
      # The agent by path, because this example lives inside it and should
      # always build against the library it ships with.
      {:nerves_hub_link_atomvm_esp32, path: "../..", manager: :rebar3, override: true},
      {:atomvm_websocket_client,
       github: "nerves-hub/atomvm_websocket_client", manager: :rebar3, override: true}
    ]
  end
end

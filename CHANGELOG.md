# Changelog

Notable changes to this library. It follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Built on 0.2.0, with the iobee fork's changes carried over. Where both
  had one, the download keeps this fork's: the retries of 0.2.0 (`max_retries`,
  `retry_backoff`, five attempts in all) are replaced by the resume below, and
  its errors are not wrapped in `download_failed`. A 5xx is still tried again,
  and a server that ignores `Range` still has the archive taken from the start.
- The download's idle limit is 0.2.0's `download_idle_ms`, 120 s by default; it
  was `download_stall_ms`, 60 s, here.

### Added

- Events tagged with a pid for a port handle -- the C port of
  atomvm_websocket_client before nerves-hub/atomvm_websocket_client 40c3917,
  on AtomVM 0.7 -- are taken for the current connection, so the agent joins
  with the transport a device was built with, not only a newer one.
- A socket closed for a download no longer reconnects on its old
  transport's `closed`, which the pid alias above let through: the second TLS
  session ran a board without PSRAM out of memory halfway through.
- `network_interface` may be a function, asked on each join and download,
  for a device that moves between networks without restarting the agent.
- A status update made while the socket is closed for a download (`started`,
  `completed`, `failed`) is sent once the device has joined again, in order.
- A download whose connection goes quiet (`resume_after_ms`, 10 s by default),
  fails or closes short reconnects and asks for the rest, `Range: bytes=N-`; it
  fails once `resumes` connections in a row (3) brought no new byte, so a slow
  link may take as many connections as it needs. After one that brought
  nothing it waits `resume_after_ms` times the count before the next, so a
  modem with no route for a few seconds, failing every connect at once, does
  not spend them all in a fraction of a second. Over a cellular modem
  connections stopped carrying data after 40–75 s, and the update failed. The
  connection is read by a process of its own, stopped before the next one
  connects. The owner hears `{download_resumed, Offset}`; a resume counts as
  progress against `download_idle_ms`. The sha256 still covers the whole
  archive.

- The owner hears `{download_pause, Ms}` as a download ends (done, failed or
  stalled): the longest it went without progress. With the socket closed for the
  download nothing else of it reaches NervesHub, and it tells a slow link from
  one that stops now and then, against `download_idle_ms`.

- A download with no progress for `download_idle_ms` (120 s by default) is
  stopped and reported as failed (`download_stalled`): AtomVM's `ssl:recv/2`
  has no deadline, and a connection that stopped carrying data held the update
  forever.
  It keeps one timer at a time: on AtomVM each timer is a process until it
  fires, and one per progress percentage ran a board without PSRAM out of
  memory halfway through a fast download.
- The owner hears `{download_socket, open | closed, LargestFreeBlock}` as a
  download starts: with the socket closed nothing of it reaches NervesHub.
- An application's console command with a built-in's name replaces it in
  `help` too, not only when it runs.
- The console keeps the last 20 lines entered: the up and down arrows walk
  through them, as in a shell. `clear` clears the screen.
- The `alarms` extension (0.1.0): with `extensions => [alarms]` and an
  `alarms => Fun`, the agent asks for the alarms every `alarms_interval_ms`
  (30 s by default) and sends `alarms:raised` / `alarms:cleared` as they
  change, and `alarms:snapshot` when NervesHub sends `alarms:sync`. Alarms
  raised while offline keep the time they were raised. With it attached, the
  health report leaves the `alarms` key out. A `Fun` of one argument is given
  the set it returned last time, for hysteresis without state of its own; a
  callback that fails leaves what was raised as it was.
- `ping_interval_ms => Ms` sets how often the socket sends WebSocket pings.
  ESP-IDF's default is every 10 seconds, which on a metered link (a cellular
  modem, say) costs more than the heartbeats; NervesHub needs only the
  heartbeats to keep the socket.
- `alarms => Fun` puts the application's alarms on the health report: called
  for each report, it returns the complete set raised right now,
  `#{Name => Description}`. A callback that fails or returns something else
  costs the alarms, not the report.
- `before_update => Fun` runs before an update's download starts, so the
  application can free memory first (its own TLS connections, say). It hears
  `update_failed` if the update does not happen.
- `console_commands => [{Name, Description, Fun}]` adds the application's own
  commands to the remote console. `Fun` gets the line's arguments and returns
  the output; `help` lists them, and one that raises prints the error.
  `{Section, Name, Description, Fun}` puts one in a section of `help`.

### Changed

- `help` lists the commands by section: the built-in ones in `device` and
  `network`, an application's in the section it names (`application` if none).
- `keep_open_above => Bytes` keeps the socket open while an update downloads
  when the largest free block of heap is at least `Bytes`. The device stays
  online, NervesHub sees the download's progress, and a failure is reported at
  once; then the socket reconnects, since NervesHub offers an update again only
  on a join. Without it the socket closes as before.

### Fixed

- A send the transport refused with anything but `{error, _}` crashed the
  agent, and its owner with it: atomvm_websocket_client answers a bare
  `not_connected` when the socket closed under a queued send. Any refusal is now
  `{send_failed, Reason}`.

- `capture_io` with `register` captures by the name, through one capture
  registered as `nh_io_capture`. An agent started again under the name used to
  get a new capture each time, and the old one stayed alive sending to the dead
  agent, along with every process that had inherited it.

- Console output goes up in pieces of at most 256 bytes. Each `up` is
  JSON-encoded in the agent, which on AtomVM costs the process many times the
  output's size in heap: a 2 KB answer with quotes in it took more than an
  ESP32 without PSRAM had in one block, and the device panicked.
- An update's download no longer starts until the closed socket's transport is
  gone and its memory is back. Closing returned first, the download's TLS
  handshake took nearly every free byte, and the transport's port then could
  not allocate the few it needed to report its own exit: "Cannot handle out of
  memory", abort, reboot. On an ESP32 without PSRAM an update took 13 to 19
  attempts; with this, it installs first time.
- An armed update is no longer downloaded again before the reboot. The socket
  reopens once an update is written, and NervesHub, still seeing the old
  firmware, offers it again; downloading it wrote into the other slot, which
  by then holds the previous firmware -- the one a failed update goes back to.

## [0.2.0] - 2026-09-24

Upgrading changes what a device does by default. **Changed** lists what to
check before rolling this out to a fleet.

### Changed

- Firmware is on trial after an update, and on by default. An update that does
  not reach NervesHub within three boots, or within five minutes of any one of
  them, is reverted and the device restarts into what it ran before. Nothing
  reverted before. `firmware_trial => off` keeps the old behaviour, and
  `reboot => manual` reverts without restarting.
- The agent reconnects, not the transport. It opens the transport with
  `disable_auto_reconnect => true`, and a transport other than
  `websocket_client` must honour that or it will reconnect twice.
- New events reach the handler: `{update_mode, Mode, Allowed}` after every
  join, and `{firmware_trial, Slot, Boot}`, `{firmware_reverted, Slot}`,
  `{update_rejected, Reason}` and `{extension_detached, Name}` when they apply.
  A `gen_server` handler without a catch-all `handle_info/2` clause crashes on
  the first one it does not match.
- The extensions topic is joined after the device topic rather than alongside
  it: once NervesHub says which versions it speaks, or after five seconds.
- Against a NervesHub that speaks logging 0.1.0, log lines are sent in batches
  and arrive up to `log_flush_ms`, 10 seconds by default, after they were
  logged.

### Fixed

- A device authenticating with a shared secret could not reconnect once its
  first connection was more than 90 seconds old. The transport reconnected by
  itself and replayed the headers it was opened with, and NervesHub refuses a
  signature that old, so a Wi-Fi drop, a server deploy or the Reconnect button
  left the device refused until it rebooted. The agent now reconnects itself,
  with backoff and jitter, and signs each connection as it opens it.

### Added

- `device_api_version` 2.4.0 in the join, which is what NervesHub gates support
  scripts, extension negotiation and device-managed updates on. Before this it
  treated every device as 1.0.0.
- Support scripts: `scripts/run` runs console commands, one per line, and
  answers with their output. `reboot` is refused in a script.
- The full set of update statuses: `received`, `started` with the network
  interface, `completed`, `ignored` and `rescheduled` alongside `failed`.
- `apply_update/2`, `ignore_update/2` and `reschedule_update/3`, for an
  application running with `updates => manual`.
- Device-managed updates: `check_for_update/1`, `request_update/1`,
  `set_update_mode/2` and `update_mode/1`.
- Downloads resume from the last byte received after a dropped connection,
  retried with backoff, and a download that goes quiet is given up on.
- Firmware on trial is reverted if it does not join NervesHub within three
  boots or five minutes of one, and the join reports `firmware_validated` and
  `firmware_auto_revert_detected`. See `firmware_trial`.
- `report_network_interface` after every join. See `network_interface`.
- Extensions negotiate versions from NervesHub's `extensions:get`, and follow
  an operator turning one on or off while connected.
- Logging 0.1.0: lines are batched, held across a disconnect up to
  `log_buffer`, and a gap from dropped lines is reported.

## [0.1.2] - 2026-08-24

### Fixed

- Maintainer tooling moved from `plugins` to `project_plugins`. `plugins` is
  inherited, so anything depending on this library built seven packages it had
  no use for, erlfmt and rebar3_hex among them, before compiling a line of its
  own code.

## [0.1.1] - 2026-08-24

### Fixed

- The **Installing** snippet in the README asked for a git dependency, which is
  what it was before this package was on Hex. Documentation only; no code
  changed between 0.1.0 and this.

### Added

- `RELEASING.md`, listing every file a release has to touch. The README
  dependency snippet is the one nothing checks and the one that was wrong here.

## [0.1.0] - 2026-08-24

First release. A NervesHub device agent for AtomVM on the ESP32, verified on
hardware against a running NervesHub rather than only against tests.

### Added

- Shared-secret and client-certificate authentication, and the Phoenix channel
  protocol as a pure state machine with no processes, timers or socket of its
  own.
- Firmware description read out of flash: the packbeam AtomVM booted, found
  through the boot path `esp32init` records in NVS, hashed so the digest
  matches what NervesHub derived from the same archive on upload.
- Over-the-air updates into whichever of two packbeam slots the device is not
  running from, so a refused or corrupt download leaves it running what it had.
- Firmware signing and verification. Packbeam has no signature format, so this
  defines one: an entry appended after everything it signs, verified against
  the organization's existing fwup keys, checked before the boot path moves.
  `nh-avm` signs, verifies and generates keys.
- A remote console answering NervesHub's console channel with a fixed set of
  commands, since AtomVM has no shell.
- The health, geo and logging extensions, and the `identify` and `reboot`
  actions.
- `nh_logger`, a `logger` handler that ships what an application logs, and
  `nh_io_capture`, an opt-in group leader that ships what it prints.
- `priv/atomvm`, the partition table and build settings a device needs, so the
  VM is reproducible rather than described.

[Unreleased]: https://github.com/nerves-hub/nerves_hub_link_atomvm_esp32/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/nerves-hub/nerves_hub_link_atomvm_esp32/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/nerves-hub/nerves_hub_link_atomvm_esp32/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/nerves-hub/nerves_hub_link_atomvm_esp32/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/nerves-hub/nerves_hub_link_atomvm_esp32/releases/tag/v0.1.0

# Changelog

Notable changes to this library. It follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/nerves-hub/nerves_hub_link_atomvm_esp32/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/nerves-hub/nerves_hub_link_atomvm_esp32/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/nerves-hub/nerves_hub_link_atomvm_esp32/releases/tag/v0.1.0

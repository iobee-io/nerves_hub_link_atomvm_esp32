# Examples

Two NervesHub devices for the same ESP32 board, one written in Erlang and one
in Elixir. They do the same thing, and the pair is the test of whether this
library is usable from Elixir without a wrapper in between.

| | |
| --- | --- |
| [smart_kiosk_avm](smart_kiosk_avm) | Erlang, rebar3 |
| [smart_kiosk_ex](smart_kiosk_ex) | Elixir, mix and [ExAtomVM](https://github.com/atomvm/exatomvm) |

Both bring up WiFi and SNTP, report the packbeam they booted, connect over a
shared secret, and then join the console, attach the health, geo and logging
extensions, and take an over-the-air update. The Elixir one also blinks the
onboard LED on `identify`, and turns on `capture_io` so that what it prints
reaches NervesHub.

What they print is the point of a bench run: the metadata read out of flash
should match what NervesHub derived from the same archive when it was
uploaded.

## Before building

Both need a config module with a WiFi password and a NervesHub shared secret,
which is why neither is committed:

```
cp smart_kiosk_avm/src/config.erl.example smart_kiosk_avm/src/config.erl
cp smart_kiosk_ex/lib/config.ex.example   smart_kiosk_ex/lib/config.ex
```

The transport,
[atomvm_websocket_client](https://github.com/nerves-hub/atomvm_websocket_client),
is fetched for you. It is also an ESP-IDF component, so the AtomVM firmware has
to be built with it. See that repo's README.

To build an example against a working copy of the transport rather than the
published one, drop a symlink in `smart_kiosk_avm/_checkouts` (rebar3 prefers
it over the dependency) or point the mix dependency at a path. Neither is
committed.

## Building

```
cd smart_kiosk_avm && rebar3 atomvm packbeam
cd smart_kiosk_ex  && mix atomvm.packbeam
```

The archive lands in `_build/default/lib/smart_kiosk_avm.avm` and
`smart_kiosk_ex.avm` respectively.

## Flashing

The offset is `main.avm` in the table on the device, and that table comes from
the AtomVM checkout these were built against, not from the `partitions.csv`
kept beside each example. Check the device rather than the file:

```
esptool.py --chip esp32 --port /dev/ttyUSB0 read_flash 0x8000 0xC00 ptable.bin
gen_esp32part.py ptable.bin
```

Writing to an offset from a stale copy of the table lands the app inside
`boot.avm`, and the only symptom is `Failed app start: invalid_avm`. The
firmware is intact but nothing will boot until the boot image is written
again.

```
esptool.py --chip esp32 --port /dev/ttyUSB0 --baud 460800 \
  write_flash 0x270000 smart_kiosk_ex.avm
```

After the first flash, updates go over the air. The device installs into
whichever of `main.avm` and `alt.avm` it is not running from, so an update
never writes over what is currently booted.

## The VM underneath

Neither example runs on a stock AtomVM. The WebSocket transport is an ESP-IDF
component, updates need a partition table with two packbeam slots rather than
the one stock has, and verifying signatures needs `AVM_USE_LIBSODIUM=ON`.

The parts that differ ship in the agent's `priv/atomvm`, and
[building the VM](../README.md#building-the-vm) has the steps for both
languages.

The `partitions.csv` beside each example is a copy of that table, kept for
reference when checking a flash offset. The one that matters is compiled into
the firmware, which is why the advice above is to read it off the device.

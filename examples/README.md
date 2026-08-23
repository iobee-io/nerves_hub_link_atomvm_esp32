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

## A layout with two slots

Neither example can use the stock AtomVM partition table: it has one packbeam
partition, and an update needs somewhere to go that is not the partition it is
running from. `partitions.csv` beside each example is a copy of the table these
were built and flashed with, for reference. The one the device uses is built
into the AtomVM firmware.

`libsodium` is the other reason the stock table does not fit. Ed25519
verification on AtomVM is behind `AVM_USE_LIBSODIUM`, which is off by default,
and turning it on adds around 140K to the firmware, enough to overflow the
stock `factory` partition.

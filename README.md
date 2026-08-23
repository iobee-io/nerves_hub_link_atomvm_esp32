# NervesHubLink for AtomVM on the ESP32

A NervesHub device agent for AtomVM, targeting the ESP32.

Two working devices are in [examples](examples), one written in Erlang and one
in Elixir.

## Usage

```erlang
{ok, _Pid} = nerves_hub_link:start(#{
    identifier    => <<"my-device">>,
    shared_secret => {Key, Secret}
}).
```

The calling process receives `{nerves_hub, Event}`:

| Event | Meaning |
| --- | --- |
| `{joined, Response}` | The device channel is live |
| `{join_error, Reason}` | The server refused the join |
| `{message, Event, Payload}` | A server message this library does not handle itself |
| `{update_started, Pid}` | An update is downloading |
| `{update_ready, Slot}` | Written and armed; reboot when convenient |
| `{update_failed, Reason}` | Refused, or the write failed |
| `{firmware_committed, Slot}` | The running update proved itself |
| `identify` | Blink something |
| `reboot_requested` | Only with `reboot => manual` |
| `console_joined` | Someone opened the console |
| `{disconnected, Reason}` | The socket dropped; the transport reconnects |
| `{transport_error, Reason}` | TLS or network failure |

And reports back:

```erlang
nerves_hub_link:update_progress(Pid, 42, <<"downloading">>),
nerves_hub_link:firmware_validated(Pid),
nerves_hub_link:update_failed(Pid, <<"flash write failed">>).
```

### Where it connects

Nothing above says where, because there is only one URL a device sensibly wants
and it can be worked out. `host` names a different server, `url` takes one
written out in as much detail as you like, and whatever is missing is filled in:

| Config | Result |
| --- | --- |
| (nothing) | `wss://devices.nervescloud.com/device-socket/websocket?vsn=2.0.0` |
| `host => "nh.example.com"` | `wss://nh.example.com/device-socket/websocket?vsn=2.0.0` |
| `url => "ws://192.168.1.10:4000"` | `ws://192.168.1.10:4000/device-socket/websocket?vsn=2.0.0` |

Anything already written is kept, so a URL given in full passes through
untouched and an unusual mount point survives. Giving both `url` and `host` is
an error rather than a precedence rule.

The path depends on how the device authenticates. NervesHub runs two endpoints
and mounts the device socket on both: a client certificate reaches the device
endpoint, where it is at `/socket`, and a shared secret goes through the web
endpoint, where `/socket` is already the browser socket and the device socket is
at `/device-socket`. Neither path implies an authentication method by itself,
since the server reads a certificate if the connection presents one and the
headers otherwise.

### Authentication

Either `shared_secret => {Key, Secret}` or `client_cert => {CertPem, KeyPem}`,
an organization's choice, and NervesHub accepts both. One of them is required.

A shared-secret signature is time-bound: NervesHub refuses one signed more than
90 seconds ago. An ESP32 boots at the epoch, so the clock has to be set before
connecting or every signature is decades stale. `start/1` refuses with
`{error, {clock_not_set, Now}}` rather than letting the socket answer a bare
401.

### Options

| Option | Default | |
| --- | --- | --- |
| `identifier` | required | The device's name on NervesHub |
| `shared_secret` | | `{Key, Secret}` |
| `client_cert` | | `{CertPem, KeyPem}` |
| `host` | `devices.nervescloud.com` | |
| `url` | | A URL in as much detail as you like |
| `verify` | `crt_bundle` | Or `{cacert_pem, Pem}`, or `none` |
| `firmware` | `boot` | Where the running firmware's description comes from |
| `firmware_keys` | none | Public keys; configuring any requires signatures |
| `request_firmware_keys` | `false` | Also ask the server for the org's keys |
| `updates` | `auto` | `manual` reports the offer and does nothing |
| `reboot` | `auto` | `manual` reports `reboot_requested` instead |
| `console` | `false` | Join NervesHub's console channel |
| `extensions` | none | `all`, or any of `health`, `geo`, `logging` |
| `capture_io` | `false` | Send what the application prints |
| `register` | none | Register the agent under a name |
| `handler` | the caller | Where `{nerves_hub, Event}` goes |
| `heartbeat_ms` | 30000 | |
| `transport` | `websocket_client` | |

## Updates

`updates => auto` downloads what NervesHub offers into whichever of the two
packbeam slots the device is not running from, arms it, and reports
`{update_ready, Slot}`. Rebooting is left to the application, because only it
knows whether the device is in the middle of something.

Writing to the inactive slot is what makes a failed update survivable: the
running archive is never overwritten, so a refused or corrupt download leaves
the device running what it had.

### Signing

Configuring `firmware_keys` is what asks for signatures. A device with keys
refuses any update they do not cover, including one carrying no signature at
all, and refuses it *before* the boot path moves, so a rejected archive sits in
a slot nothing boots from. A device with no keys installs what it is sent.

The keys are the organization's existing fwup public keys. An fwup private key
is a 32-byte Ed25519 seed followed by its public key, and that trailing half is
byte for byte the `.pub` NervesHub already stores, so signing packbeams needs no
new key management.

Packbeam has no signature format of its own, so this defines one: an entry named
`nerves_hub/signature` appended last, carrying `"NH1"`, a version, and 64 bytes.
The signed range is every byte before that entry begins. Because it is appended,
nothing before it moves, and both ends compute the same range without agreeing
on anything else. It is a data file, the class AtomVM skips when looking for
code, so a signed archive still boots on a stock VM.

`nh-avm` signs and verifies:

```
nh-avm sign   --key fwup-key.priv --in app.avm --out app-signed.avm
nh-avm verify --key fwup-key.pub  --in app-signed.avm
nh-avm keygen --priv my.priv --pub my.pub
```

Verification on the device needs an AtomVM built with `AVM_USE_LIBSODIUM=ON`,
which is off by default. Without it a device configured with keys reports
`verification_unavailable` rather than quietly accepting the update.

## The console

`console => true` joins NervesHub's console channel. On Nerves, `nerves_hub_link`
answers that channel with an IEx session. AtomVM has no shell, so this answers
with a fixed set of commands instead: `help`, `info`, `firmware`, `memory`,
`partitions`, `net`, `geo`, `signature`, `uptime`, `reboot`.

It reports, and it reboots. It will not evaluate Erlang, and it is not a way in
to a running system.

## Extensions

`extensions => all` attaches the three NervesHub extensions: `health` reports
memory and uptime, `geo` reports a location, and `logging` carries log lines.

`nh_logger` is a `logger` handler that sends everything logged, and
`nerves_hub_link:send_log/3` sends one line directly.

### Never log a binary

AtomVM's `logger` accepts a list or a map and raises `badarg` on anything else,
*before* any handler sees the event. A binary message does not produce a
mangled log line; it takes down the process that logged it.

```erlang
logger:info("started"),           %% ok, a list
logger:info(#{event => started}), %% ok, a map
logger:info(<<"started">>).       %% badarg, and the caller dies
```

This bites Elixir hardest, because `Logger.info("...")` is muscle memory and
Elixir strings are binaries. Elixir has no `Logger` on AtomVM, so Elixir code
calls `:logger` directly and hits this on the first line it writes. Use a
charlist (`~c"started"`) or a map, or call `nerves_hub_link:send_log/3`, which
takes a binary and is the safe path.

`capture_io => true` also sends what the application *prints*, which on AtomVM
is most of how code reports anything. It makes a capture process the group
leader, so `io:format/2`, `IO.puts/1` and `IO.inspect/1` reach NervesHub as well
as the console. Read `nh_io_capture` before turning it on: the failure mode of a
group leader is a printing process that waits forever, and there is one
interaction with `logger_std_h` that duplicates every logged line.

## Describing the firmware

The firmware NervesHub manages is the packbeam, not the ESP-IDF image
underneath. That image is AtomVM itself, and it is replaced by a different
mechanism on a different schedule.

`firmware` says where the description comes from:

| Value | Behaviour |
| --- | --- |
| `boot` | The packbeam AtomVM booted. **Default** |
| `{partition, Label}` | A named partition instead |
| `{metadata, Map}` | Supply it directly |
| `none` | Join without describing the firmware |

`boot` can be the default because it is not a guess. AtomVM's `esp32init`
records where it booted from in NVS under `atomvm`/`boot_path`, so the agent
reads the answer and stays right after an update that switched slots. This is
the one place AtomVM is *better* off than ESP-IDF, where a device cannot ask
which of `ota_0`/`ota_1` it is running because there is no
`esp_ota_get_running_partition()` binding.

A device that cannot read its firmware description refuses to start rather than
connecting without one, which would look like a healthy device that never needs
updating.

## The channel protocol

`nh_channel` is the Phoenix channel protocol as a pure state machine: no
processes, no timers, no socket. Each call returns a new state and a list of
actions:

```erlang
State0 = nh_channel:new(JoinParams),
{State1, Actions} = nh_channel:connected(State0),   %% on every connection
{State2, Actions1} = nh_channel:handle_text(Frame, State1).
```

```
{send, Binary}   %% write this to the socket
{event, Term}    %% tell the application this happened
```

Being pure is what let the protocol be tested against a real NervesHub from a
desktop, over an unrelated WebSocket client, before any of it ran on a device.

Two details the wire format makes easy to get wrong, both covered by tests:

* The device joins the topic `device`, unqualified. NervesHub's serializer
  rewrites it to `device:<id>` on the way in.
* Heartbeats go to `phoenix` with a `null` join reference, not to the device
  topic.

A channel does not survive a socket reconnect, so `connected/1` must be called
on every connection. A client that reconnects the socket without rejoining looks
healthy and silently stops receiving updates.

## What the device reports

| Parameter | Source |
| --- | --- |
| `atomvm_app_name` | the packbeam's application name |
| `atomvm_app_version` | its `vsn` |
| `atomvm_avm_sha256` | SHA-256 of the packbeam |
| `atomvm_version` | `erlang:system_info(atomvm_version)` |

So the device reports what is actually running rather than a constant it was
compiled with. There is no UUID: NervesHub derives one from the digest using the
same rule it applied to the uploaded archive, which keeps the rule in one place
where an agent cannot get it subtly wrong.

`atomvm_app_version` is the firmware. `atomvm_version` is the VM it runs on,
which no packbeam can know.

### Hashing the right bytes

The digest has to cover the archive and nothing else, because that is what
NervesHub hashed on upload, and a partition is much larger than the archive
written into it.

The archive's own length is recoverable exactly. `packbeam_api:write_packbeam/2`
ends every archive with `create_header(0, 0, <<"end">>)`, a zeroed 12-byte
header followed by `"end\0"`, so the archive ends 16 bytes after the terminator
starts. `nh_packbeam:byte_length/1` walks to it.

`nh_flash` does that walk against flash a chunk at a time, hashing as it goes
and keeping only the one entry it needs, so the archive is never held in memory.

## The agent

`nh_agent` is the only process: it opens the socket, joins on every `connected`,
heartbeats on a deadline, and surfaces messages to its owner as
`{nerves_hub, Event}`.

```erlang
{ok, _} = nh_agent:start(#{
    url           => "wss://nh.example.com",
    identifier    => <<"my-device">>,
    shared_secret => {Key, Secret},
    metadata      => Metadata,
    verify        => crt_bundle
}).
```

The transport is a module rather than a hard dependency, which is what let the
agent be tested against a real NervesHub from a desktop before any of it ran on
a chip. `websocket_client` from
[atomvm_websocket_client](https://github.com/nerves-hub/atomvm_websocket_client)
is the one it uses on a device.

## Status

✅ means tested on an ESP32 against NervesHub.

| | |
| --- | --- |
| Shared-secret authentication | ✅ |
| Working the URL out from a host | ✅ |
| Channel join and heartbeat | ✅ |
| Packbeam parsing | ✅ cross-checked against NervesHub's own parser |
| Reading metadata from flash | ✅ digest matches what the server derived |
| Over-the-air updates | ✅ installed into the inactive slot, both directions |
| Signature verification | ✅ a signed archive installs, a tampered one is refused |
| Remote console | ✅ a fixed set of commands, since AtomVM has no shell |
| Health, geo and logging extensions | ✅ |
| `identify` and `reboot` | ✅ |
| Capturing `io:format` and `IO.puts` | ✅ |
| Client certificates | accepted in config, never run on a device |

Transport comes from
[atomvm_websocket_client](https://github.com/nerves-hub/atomvm_websocket_client).

## License

Apache-2.0 OR LGPL-2.1-or-later.

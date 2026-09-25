# tenda-sp15-homeassistant

Run a **Tenda Beli** smart plug entirely on your own network — no vendor app,
no vendor cloud — and generate the Home Assistant configuration for it.

One script pairs the plug against a server *you* choose, finds it on your LAN,
and prints the YAML you paste into Home Assistant.

```
$ ./tenda-sp15.sh pair
...
✓ found SP15, firmware V1.1.0.33(311)_SP15_EU, mac d8:32:14:xx:xx:xx
✓ credentials accepted — the plug is rebooting onto your network
✓ plug is at 192.168.1.144
✓ local API is answering
```

## Tenda Beli is not Tuya

This is the thing that wastes everyone's afternoon, so it goes first.

Most white-label Wi-Fi plugs are rebadged Tuya hardware, and the usual advice —
"pair it in Smart Life, then add the Tuya integration" — works. **Tenda Beli is
not one of them.** It runs Tenda's own cloud and its own protocol. Smart Life
and Tuya Smart will never discover these plugs, no matter how many times you
reset them. LocalTuya will not help either.

The tell is the pairing hotspot: a Tuya device announces itself as
`SmartLife-XXXX`, while a Beli unit announces `Tenda_PowerStrip_xxxx` or
`Tenda_Smart_Plug_xxxx`.

The good news is that Beli firmware is far easier to live with than Tuya's. Each
unit serves a plain, unauthenticated HTTP API on port 5000 — in pairing mode and
on your LAN afterwards — and the provisioning call lets you name the server it
reports to. Point that at a host you control and the plug never contacts the
vendor again. Nothing is flashed, nothing is opened, nothing is soldered, and
the device keeps working exactly as it did.

## What you get

- Every outlet as an independent Home Assistant `switch` entity
- Purely local control: no cloud, no account, no app, no internet dependency
- Optional Wi-Fi signal sensor
- A CLI for scripting and debugging outside Home Assistant

## Requirements

`bash`, `curl`, and a computer whose Wi-Fi you can point at the plug's hotspot
for a couple of minutes. macOS and Linux are both supported. No Python, no
dependencies, no HACS.

## Quick start

```sh
git clone https://github.com/freedreamer82/tenda-sp15-homeassistant
cd tenda-sp15-homeassistant
```

1. Hold the plug's button until the LED blinks (on a strip it alternates red
   and blue).
2. Join the plug's open Wi-Fi network from your computer. You will lose internet
   access for a minute — that is expected.
3. Run the guided setup:

   ```sh
   ./tenda-sp15.sh pair
   ```

   It shows you what the plug can see, asks for your 2.4 GHz SSID and password,
   and asks which server the plug should report to. Your Home Assistant host is
   the natural answer; any address you control will do.
4. Reconnect to your normal Wi-Fi when prompted. The script finds the plug by
   MAC address and prints the Home Assistant configuration.

The password is read without echo and is never written to disk or logged.

## Commands

| Command | What it does |
| --- | --- |
| `pair` | Guided setup: probe, provision, locate, print config |
| `info [ip]` | Device details, outlet states, visible networks. Defaults to `192.168.25.1`, the pairing-mode address |
| `find <mac>` | Locate a provisioned plug on the LAN |
| `config <ip>` | Print the Home Assistant YAML |
| `status <ip>` | Show every outlet's state |
| `switch <ip> <mark> on\|off` | Toggle one outlet, with the result verified |
| `switch <ip> ALL on\|off` | Toggle the whole unit (asks for confirmation) |

Outlet identifiers ("marks") come from the device. A strip typically reports
`PLUG1`, `PLUG2`, `PLUG3` and `USB`; a single plug reports one. Run `status` to
see what yours has.

## Home Assistant

`./tenda-sp15.sh config <ip>` emits one `switch.rest` entity per outlet. Put the
key in `configuration.yaml`:

```yaml
switch: !include switches.yaml
```

and the generated list in `switches.yaml`.

Two YAML mistakes cost more time than the whole integration, so they are worth
stating plainly:

- **An `!include`d file must not repeat its own key.** `switches.yaml` starts
  directly with `- platform: rest`. The `switch:` key lives in
  `configuration.yaml` and nowhere else.
- **A duplicate top-level key silently destroys one of the two blocks.** If you
  already have a `sensor:` section, add the optional signal sensor *inside* it.
  Home Assistant logs this as a warning, not an error, and quietly drops
  whichever block loses.

New entities do not appear on a manually-configured dashboard by themselves.
Check **Developer Tools → States** for `switch.power_strip_*` before concluding
that something is broken.

Finally, reserve the plug's address in your router's DHCP settings. The
configuration is written against an IP, so a changed lease turns every entity
`unavailable`.

## Protocol reference

Unauthenticated HTTP on port 5000. In pairing mode the plug is at
`192.168.25.1`; afterwards it is wherever DHCP puts it.

| Method | Endpoint | Purpose |
| --- | --- | --- |
| `GET` | `/getDetail` | Model, firmware, MAC, serial, RSSI, timezone offset |
| `GET` | `/getSta` | Unit state and the list of outlets |
| `GET` | `/getWifiInfo` | Networks the plug can see, with signal strength |
| `POST` | `/getWifi` | Same scan, triggered fresh |
| `POST` | `/setSta` | Switch an outlet |
| `POST` | `/guideDone` | Provision Wi-Fi credentials and the report server |

Unknown paths answer `Unknown REQUEST`, which makes capability probing reliable.

Provisioning payload:

```json
{
  "account":  "local@local",
  "key":      "your-wifi-password",
  "ssid":     "your-ssid",
  "location": "Europe/Rome",
  "timezone": 120,
  "server":   "192.168.1.50"
}
```

`timezone` is an offset in **minutes**. `server` is the whole point: the plug
talks to that host instead of the vendor's endpoint. `account` is not validated.

Switching one outlet:

```json
{"sub_device": [{"dev_name": "PLUG1", "action": 0}]}
```

Switching the whole unit:

```json
{"status": 0}
```

Several outlets can be given in one array. `getSta` reports each outlet under
both `mark` and `dev_name` (identical values), plus a unit-level `status` that
is true when any outlet is on.

## Three firmware behaviours that will bite you

All three were found the hard way, with a strip clicking on and off on the desk.
They are the reason this repository exists rather than a three-line gist.

**`status` reports, `action` commands.** `getSta` describes each outlet with a
`status` field, and the obvious move is to write that same field back. It does
not work — not because it is rejected, but because it is *accepted* and applied
somewhere else. The write-side field is `action`, and it only exists inside the
`sub_device` array. This asymmetry between the read and write vocabulary is the
single biggest time sink in this protocol.

**Anything carrying a command outside `sub_device` hits the whole unit.** Send
`{"mark":"PLUG1","status":0}` and the strip does not reject the unknown shape:
it falls through to the unit-level switch and cuts power to *every* outlet. So
does `{"dev_name":"PLUG1","action":0}` at the root. A payload that is merely
misshapen, not invalid, will blackout the strip. `tenda-sp15.sh` always nests
the command and validates the outlet name against the device's own list.

**`setSta` returns `resp_code: 0` for payloads it silently ignores.** The reply
confirms nothing. `{"sub_device":[{"mark":"PLUG1","action":1}]}` — `mark`
instead of `dev_name` — returns success and does absolutely nothing, even
though `mark` is the very field `getSta` uses to name that outlet. Never trust
the response; read the state back. The script does this after every write.

## Limitations

- **No energy monitoring on the SP15.** `getEnergy` and `app/EnergyGet` return
  `Unknown REQUEST`. The SP9 does report power and accumulated energy; if you
  have one, the projects listed below already handle it.
- **The API is unauthenticated.** Anyone on your LAN can enumerate and switch
  these outlets over plain HTTP. That is a property of the firmware, not of this
  script. Treat the plug as you would any other unauthenticated IoT device: put
  it on an IoT VLAN if you have one, and do not expose port 5000 beyond your
  network.
- **Provisioning is IP-based.** Reserve the lease.
- Schedules and timers configured through the vendor app are not exposed here.
  Use Home Assistant automations instead — they are better anyway.

## Tested on

- Tenda Beli **SP15** power strip (3 outlets + USB), firmware
  `V1.1.0.33(311)_SP15_EU`, hardware `V1.0`, EU model
- macOS, against Home Assistant 2026.9

The protocol is shared across the Beli range, so SP3 and SP9 are very likely to
work. Outlet marks are read from the device rather than hard-coded, so a unit
with a different layout should be handled correctly. Reports welcome.

## Credits

- [Gough Lui](https://goughlui.com/2020/02/22/reverse-engineer-tenda-beli-sp3-smart-wi-fi-plug-protocol/)
  reverse-engineered the SP3 protocol and discovered that the provisioning
  call accepts an arbitrary `server`. That single finding is what makes a
  cloud-free setup possible at all.
- [nohous/tenda-beli](https://github.com/nohous/tenda-beli) — protocol notes
- [vladimirus/ha-tenda-sp9](https://github.com/vladimirus/ha-tenda-sp9) — a full
  custom component for the SP9, including the rendezvous/provisioning servers
- [tendabeli2mqtt](https://hub.docker.com/r/tediore/tendabeli2mqtt) — MQTT bridge

This project takes a deliberately smaller approach: no custom component, no
broker, no add-on. Core `switch.rest` entities and a shell script, so there is
nothing to keep up to date as Home Assistant evolves.

## License

MIT

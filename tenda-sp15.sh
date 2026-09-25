#!/usr/bin/env bash
#
# tenda-sp15.sh — provision a Tenda Beli smart plug against your own server
# and generate a Home Assistant configuration for it. No app, no vendor cloud.
#
# https://github.com/YOURNAME/tenda-sp15-ha
#
set -uo pipefail

AP_IP="192.168.25.1"        # the plug's address while in pairing (AP) mode
PORT=5000                   # the plug's HTTP API port, in AP mode and on the LAN
TIMEOUT=8

# ---------------------------------------------------------------- utilities

c_bold=$'\033[1m'; c_dim=$'\033[2m'; c_red=$'\033[31m'
c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_off=$'\033[0m'
[ -t 1 ] || { c_bold=; c_dim=; c_red=; c_grn=; c_yel=; c_off=; }

say()  { printf '%s\n' "$*"; }
hdr()  { printf '\n%s%s%s\n' "$c_bold" "$*" "$c_off"; }
ok()   { printf '%s✓%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%s!%s %s\n' "$c_yel" "$c_off" "$*"; }
die()  { printf '%s✗ %s%s\n' "$c_red" "$*" "$c_off" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

api_get()  { curl -fsS -m "$TIMEOUT" "http://$1:$PORT/$2" 2>/dev/null; }
api_post() { curl -fsS -m "$TIMEOUT" -X POST "http://$1:$PORT/$2" \
                  -H 'Content-Type: application/json' -d "$3" 2>/dev/null; }

# field <json> <key> — pull a string or number field out of a flat JSON blob
field() { printf '%s' "$1" | sed -n "s/.*\"$2\":\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" | head -1; }

# mark_status <json> <MARK> — current 0/1 state of one outlet
mark_status() {
  printf '%s' "$1" | grep -o "{\"mark\":\"$2\",\"status\":[01]" | head -1 | grep -o '[01]$'
}

# marks <json> — list the outlet identifiers this unit exposes
marks() { printf '%s' "$1" | grep -o '"mark":"[^"]*"' | sed 's/"mark":"//;s/"//' ; }

# norm_mac <mac> — strip leading zeros per octet, lowercase (arp(8) prints d8:32:14:b2:5f:c0
# on Linux but 8:a6:bc:... on macOS, so both sides must be normalised before comparing)
norm_mac() {
  printf '%s' "$1" | tr 'A-Z' 'a-z' | tr ':' '\n' | sed 's/^0\([0-9a-f]\)$/\1/' | paste -sd: -
}

require_plug() {
  local ip="$1" d
  d=$(api_get "$ip" getDetail) || true
  [ -n "$d" ] || die "no plug answering at $ip:$PORT
  In pairing mode: hold the button until the LED blinks, join the plug's
  Wi-Fi network (Tenda_PowerStrip_xxxx / Tenda_Smart_Plug_xxxx), then retry."
  printf '%s' "$d"
}

# ------------------------------------------------------------------ command: info

cmd_info() {
  local ip="${1:-$AP_IP}" d s
  d=$(require_plug "$ip")
  hdr "Device @ $ip"
  printf '  model      %s (%s)\n' "$(field "$d" dev_model)" "$(field "$d" model)"
  printf '  firmware   %s\n'      "$(field "$d" sft_ver)"
  printf '  hardware   %s\n'      "$(field "$d" hrd_ver)"
  printf '  serial     %s\n'      "$(field "$d" sn)"
  printf '  mac        %s\n'      "$(field "$d" mac)"
  printf '  country    %s\n'      "$(field "$d" dev_country)"
  printf '  tz offset  %s min\n'  "$(field "$d" time_zone)"
  printf '  rssi       %s dBm\n'  "$(field "$d" rssi)"

  s=$(api_get "$ip" getSta)
  if [ -n "$s" ]; then
    hdr "Outlets"
    local m
    for m in $(marks "$s"); do
      local st; st=$(mark_status "$s" "$m")
      printf '  %-8s %s\n' "$m" "$([ "$st" = 1 ] && echo on || echo off)"
    done
  fi

  local w; w=$(api_get "$ip" getWifiInfo)
  if [ -n "$w" ]; then
    hdr "Visible 2.4 GHz networks"
    printf '%s' "$w" | grep -o '"rssi":-[0-9]*,"ssid":"[^"]*"' \
      | sed 's/"rssi"://; s/,"ssid":"/ dBm  /; s/"$//' | sort -n | awk '{printf "  %s\n",$0}'
  fi
  printf '\n'
}

# ------------------------------------------------------------------ command: pair

cmd_pair() {
  local d mac ssid pass server tz_off tz_name resp

  hdr "Step 1/4 — talk to the plug"
  say "${c_dim}Join the plug's own Wi-Fi network first (it is open, no password).${c_off}"
  d=$(require_plug "$AP_IP")
  mac=$(field "$d" mac)
  ok "found $(field "$d" dev_model), firmware $(field "$d" sft_ver), mac $mac"

  hdr "Step 2/4 — where should it connect?"
  say "${c_dim}Networks the plug can currently see:${c_off}"
  api_get "$AP_IP" getWifiInfo | grep -o '"ssid":"[^"]*"' \
    | sed 's/"ssid":"//;s/"//' | sort -u | awk '{printf "  %s\n",$0}'
  printf '\n'

  read -r -p "Your 2.4 GHz SSID: " ssid
  [ -n "$ssid" ] || die "an SSID is required"
  read -r -s -p "Wi-Fi password: " pass; printf '\n'

  say ""
  say "${c_dim}The plug uploads telemetry to whatever host you name here. Point it at a"
  say "machine you control — your Home Assistant box is the usual answer — and it"
  say "will never reach the vendor cloud again.${c_off}"
  read -r -p "Server host/IP for the plug to report to: " server
  [ -n "$server" ] || die "a server is required"

  tz_off=$(date +%z | awk '{s=substr($0,1,1); h=substr($0,2,2); m=substr($0,4,2);
           v=h*60+m; if (s=="-") v=-v; print v}')
  tz_name=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')
  [ -n "$tz_name" ] || tz_name="UTC"
  say ""
  say "Timezone detected: ${c_bold}$tz_name${c_off} (offset ${tz_off} min)"
  read -r -p "Press ENTER to accept, or type another IANA name: " tz_in
  [ -n "${tz_in:-}" ] && tz_name="$tz_in"

  hdr "Step 3/4 — provisioning"
  resp=$(api_post "$AP_IP" guideDone \
    "{\"account\":\"local@local\",\"key\":$(json_str "$pass"),\"location\":\"$tz_name\",\"server\":\"$server\",\"ssid\":$(json_str "$ssid"),\"timezone\":$tz_off}")
  unset pass
  [ -n "$resp" ] || die "the plug did not answer /guideDone"
  say "  response: $resp"
  ok "credentials accepted — the plug is rebooting onto your network"

  hdr "Step 4/4 — find it again"
  say "${c_bold}Reconnect this computer to your normal Wi-Fi now.${c_off}"
  read -r -p "Press ENTER once you are back on your LAN... "
  cmd_find "$mac"
}

# json_str <text> — quote a string safely for embedding in JSON
json_str() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/'
}

# ------------------------------------------------------------------ command: find

cmd_find() {
  local want="${1:-}" base ip target found=""
  [ -n "$want" ] || die "usage: $0 find <mac-address>"
  target=$(norm_mac "$want")

  base=$(ip_prefix) || die "could not work out this machine's subnet"
  say "Sweeping ${base}.0/24 for $want ..."
  for i in $(seq 1 254); do ping -c1 -W 1 "${base}.${i}" >/dev/null 2>&1 & done
  wait 2>/dev/null

  while read -r ip hw; do
    [ "$(norm_mac "$hw")" = "$target" ] && { found="$ip"; break; }
  done < <(arp -an 2>/dev/null | sed -n 's/^? (\([0-9.]*\)) at \([0-9a-fA-F:]*\).*/\1 \2/p')

  if [ -z "$found" ]; then
    warn "not found by MAC. It may still be booting — wait 30s and retry,"
    warn "or read its address off your router's DHCP lease table."
    return 1
  fi

  ok "plug is at $found"
  if api_get "$found" getSta >/dev/null; then
    ok "local API is answering"
    printf '\n'
    cmd_config "$found"
  else
    warn "host is up but port $PORT is not answering yet; give it a moment"
  fi
}

ip_prefix() {
  local myip
  myip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)
  [ -n "$myip" ] || myip=$(hostname -I 2>/dev/null | awk '{print $1}')
  [ -n "$myip" ] || return 1
  printf '%s' "${myip%.*}"
}

# ---------------------------------------------------------------- command: config

cmd_config() {
  local ip="${1:-}" s
  [ -n "$ip" ] || die "usage: $0 config <plug-ip>"
  s=$(api_get "$ip" getSta) || true
  [ -n "$s" ] || die "no plug answering at $ip:$PORT"

  cat <<YAML
# ---------------------------------------------------------------------------
# Home Assistant — Tenda Beli, fully local
#
# In configuration.yaml:
#
#     switch: !include switches.yaml
#
# In switches.yaml, paste everything below. Do NOT repeat the "switch:" key
# inside an !include-d file: the key lives in configuration.yaml, the file
# holds only the value.
# ---------------------------------------------------------------------------
YAML

  local m label slug
  for m in $(marks "$s"); do
    label=$(printf '%s' "$m" | tr 'A-Z' 'a-z')
    slug=$(printf 'tenda_%s' "$label")
    cat <<YAML

- platform: rest
  name: "Power Strip ${m}"
  unique_id: ${slug}
  resource: "http://${ip}:${PORT}/setSta"
  state_resource: "http://${ip}:${PORT}/getSta"
  body_on: '{"sub_device":[{"dev_name":"${m}","action":1}]}'
  body_off: '{"sub_device":[{"dev_name":"${m}","action":0}]}'
  is_on_template: >-
    {{ value_json.data.sub_device | selectattr('mark','equalto','${m}')
       | map(attribute='status') | first == 1 }}
  headers:
    Content-Type: application/json
  scan_interval: 15
YAML
  done

  cat <<YAML

# ---------------------------------------------------------------------------
# Optional: Wi-Fi signal. This one is a sensor, so it belongs under your
# EXISTING "sensor:" key — adding a second "sensor:" silently discards one
# of the two blocks.
#
#   - platform: rest
#     name: "Power Strip Signal"
#     unique_id: tenda_rssi
#     resource: "http://${ip}:${PORT}/getDetail"
#     value_template: "{{ value_json.data.rssi }}"
#     unit_of_measurement: "dBm"
#     device_class: signal_strength
#     state_class: measurement
#     scan_interval: 300
#
# Reserve ${ip} for this plug in your router's DHCP settings, or the
# entities go unavailable the day the lease changes.
# ---------------------------------------------------------------------------
YAML
}

# ------------------------------------------------------- commands: status / on / off

cmd_status() {
  local ip="${1:-}" s m
  [ -n "$ip" ] || die "usage: $0 status <plug-ip>"
  s=$(api_get "$ip" getSta) || true
  [ -n "$s" ] || die "no plug answering at $ip:$PORT"
  for m in $(marks "$s"); do
    printf '%-8s %s\n' "$m" "$([ "$(mark_status "$s" "$m")" = 1 ] && echo on || echo off)"
  done
}

cmd_switch() {
  local ip="${1:-}" mark="${2:-}" action="${3:-}" want got s valid m
  [ -n "$ip" ] && [ -n "$mark" ] && [ -n "$action" ] \
    || die "usage: $0 switch <plug-ip> <OUTLET|ALL> <on|off>"
  case "$action" in
    on)  want=1 ;;
    off) want=0 ;;
    *)   die "action must be 'on' or 'off'" ;;
  esac

  s=$(api_get "$ip" getSta) || true
  [ -n "$s" ] || die "no plug answering at $ip:$PORT"
  valid=$(marks "$s")

  if [ "$mark" = "ALL" ] || [ "$mark" = "all" ]; then
    api_post "$ip" setSta "{\"status\":$want}" >/dev/null
    sleep 1
    s=$(api_get "$ip" getSta)
    for m in $valid; do
      printf '  %-8s %s\n' "$m" "$([ "$(mark_status "$s" "$m")" = 1 ] && echo on || echo off)"
    done
    return 0
  fi

  # An outlet name the firmware does not recognise is a no-op, but a payload
  # shaped wrongly is not: anything carrying 'action' outside the sub_device
  # array switches the WHOLE unit. Validate before sending.
  printf '%s\n' "$valid" | grep -qx "$mark" \
    || die "'$mark' is not an outlet on this unit.
  Valid outlets: $(printf '%s' "$valid" | paste -sd' ' -)"

  api_post "$ip" setSta \
    "{\"sub_device\":[{\"dev_name\":\"$mark\",\"action\":$want}]}" >/dev/null

  # setSta answers resp_code:0 even for payloads it ignores, so read back.
  sleep 1
  got=$(mark_status "$(api_get "$ip" getSta)" "$mark")
  if [ "$got" = "$want" ]; then
    ok "$mark is now $action"
  else
    die "$mark did not change (still $([ "$got" = 1 ] && echo on || echo off))"
  fi
}

# ------------------------------------------------------------------------ usage

usage() {
  cat <<TXT
${c_bold}tenda-sp15.sh${c_off} — drive a Tenda Beli smart plug without the app or the cloud

  ${c_bold}pair${c_off}                          guided setup: probe, provision, locate,
                                and print the Home Assistant config
  ${c_bold}info${c_off} [ip]                     device details, outlet states, Wi-Fi scan
                                (defaults to $AP_IP, the pairing-mode address)
  ${c_bold}find${c_off} <mac>                    locate a provisioned plug on the LAN
  ${c_bold}config${c_off} <ip>                   print the Home Assistant YAML
  ${c_bold}status${c_off} <ip>                   show every outlet's state
  ${c_bold}switch${c_off} <ip> <outlet> on|off   toggle one outlet, verified
  ${c_bold}switch${c_off} <ip> ALL on|off       toggle every outlet at once

Outlet marks come from the device itself — typically PLUG1, PLUG2, PLUG3 and
USB on a strip, or a single one on a plug. Run 'status' to see them.

Start here:
  1. Hold the plug's button until the LED blinks.
  2. Join its open Wi-Fi network from this computer.
  3. $0 pair
TXT
}

case "${1:-}" in
  pair)   shift; cmd_pair "$@" ;;
  info)   shift; cmd_info "$@" ;;
  find)   shift; cmd_find "$@" ;;
  config) shift; cmd_config "$@" ;;
  status) shift; cmd_status "$@" ;;
  switch) shift; cmd_switch "$@" ;;
  -h|--help|help|"") usage ;;
  *) die "unknown command: $1 (try --help)" ;;
esac

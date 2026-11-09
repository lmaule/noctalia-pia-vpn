#!/usr/bin/env bash
# PIA engine for the Noctalia plugin. Wraps the official `piactl` CLI and
# prints exactly one JSON object per call, so the Luau side never has to parse
# free-form text. Works on its own from a keybind too:
#
#   pia.sh status | regions | connect | disconnect | toggle
#   pia.sh login <credentials-file>      (line 1 username, line 2 password; file is deleted)
#   pia.sh logout
#   pia.sh set-region <id|auto>
#   pia.sh set <protocol|requestportforward|allowlan> <value>

set -u
export LC_ALL=C

TIMEOUT=4

find_piactl() {
  if [[ -n "${PIACTL:-}" && -x "${PIACTL}" ]]; then
    printf '%s' "$PIACTL"; return 0
  fi
  local c
  for c in "$(command -v piactl 2>/dev/null)" /usr/local/bin/piactl /opt/piavpn/bin/piactl "$HOME/.local/bin/piactl"; do
    [[ -n "$c" && -x "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# JSON string escape (backslash, quote, control chars).
js() {
  local s=${1-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/}
  s=${s//$'\t'/\\t}
  printf '"%s"' "$s"
}

ok()   { printf '{"ok":true%s}\n' "${1-}"; exit 0; }
fail() { printf '{"ok":false,"error":%s%s}\n' "$(js "$1")" "${2-}"; exit 0; }

PIA=$(find_piactl) || PIA=""
need_pia() { [[ -n "$PIA" ]] || fail "piactl not found" ',"installed":false'; }

pget() { "$PIA" -t "$TIMEOUT" get "$1" 2>/dev/null | head -n1; }

# piactl prints its own reasons on stderr; keep the last meaningful line.
run_pia() {
  local out
  out=$("$PIA" -t "$TIMEOUT" "$@" 2>&1)
  local rc=$?
  LAST_MSG=$(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d' | tail -n1)
  return $rc
}

logged_in() {
  # The account dump also carries password/token fields (blank in PIA 3.x, but
  # that is PIA's choice, not ours). Filter inside the pipe so only `loggedIn`
  # and `username` ever reach this script's memory - never a variable, file
  # or log line holding the rest.
  local fields
  fields=$("$PIA" -t "$TIMEOUT" -u dump daemon-account 2>/dev/null \
    | grep -Eo '"(loggedIn|username)"[[:space:]]*:[[:space:]]*("[^"]*"|true|false)')
  if [[ -n "$fields" ]]; then
    grep -Eq '^"loggedIn"[[:space:]]*:[[:space:]]*true$' <<<"$fields" || return 1
    USERNAME=$(sed -nE 's/^"username"[[:space:]]*:[[:space:]]*"([^"]*)"$/\1/p' <<<"$fields" | head -n1)
    return 0
  fi
  # Older clients without `dump`: trust the marker the plugin writes on login.
  [[ -n "${PIA_MARKER:-}" && -f "$PIA_MARKER" ]] && { USERNAME=$(head -n1 "$PIA_MARKER"); return 0; }
  return 1
}

cmd_status() {
  need_pia
  local state
  if ! state=$("$PIA" -t "$TIMEOUT" get connectionstate 2>/dev/null) || [[ -z "$state" ]]; then
    fail "The PIA service is not running" ',"installed":true,"daemon":false'
  fi
  state=$(head -n1 <<<"$state")
  USERNAME=""
  local li=false
  logged_in && li=true
  ok "$(printf ',"installed":true,"daemon":true,"loggedIn":%s,"username":%s,"state":%s,"region":%s,"vpnip":%s,"pubip":%s,"protocol":%s,"portforward":%s,"requestportforward":%s,"allowlan":%s' \
    "$li" "$(js "$USERNAME")" "$(js "$state")" "$(js "$(pget region)")" \
    "$(js "$(pget vpnip)")" "$(js "$(pget pubip)")" "$(js "$(pget protocol)")" \
    "$(js "$(pget portforward)")" "$(js "$(pget requestportforward)")" "$(js "$(pget allowlan)")")"
}

cmd_regions() {
  local out first=1 list="" r
  out=$("$PIA" -t "$TIMEOUT" get regions 2>&1) || fail "${out:-Could not list regions}"
  while IFS= read -r r; do
    r=${r//[[:space:]]/}
    [[ -z "$r" ]] && continue
    if (( first )); then first=0; else list+=","; fi
    list+=$(js "$r")
  done <<<"$out"
  ok ",\"regions\":[${list}]"
}

cmd_login() {
  local file=${1-}
  [[ -n "$file" && -f "$file" ]] || fail "No credentials given"
  # Whatever happens next, the plaintext file must not outlive this call.
  trap 'shred -u "$file" 2>/dev/null || rm -f "$file"' EXIT
  if run_pia login "$file"; then
    run_pia background enable || true
    local user
    user=$(head -n1 "$file")
    if [[ -n "${PIA_MARKER:-}" ]]; then
      (umask 077; printf '%s\n' "$user" >"$PIA_MARKER")
    fi
    shred -u "$file" 2>/dev/null || rm -f "$file"
    trap - EXIT
    ok ",\"username\":$(js "$user")"
  fi
  local msg=${LAST_MSG:-Sign-in failed}
  case "$msg" in
    *uthenticat*|*nvalid*|*redential*|*nauthor*) msg="Incorrect username or password" ;;
  esac
  fail "$msg"
}

cmd_logout() {
  run_pia disconnect >/dev/null 2>&1 || true
  run_pia logout || fail "${LAST_MSG:-Sign-out failed}"
  [[ -n "${PIA_MARKER:-}" ]] && rm -f "$PIA_MARKER"
  ok
}

cmd_connect() {
  # Background mode lets the daemon connect without the PIA GUI running.
  run_pia background enable || true
  run_pia connect || fail "${LAST_MSG:-Could not connect}"
  ok
}

cmd_disconnect() {
  run_pia disconnect || fail "${LAST_MSG:-Could not disconnect}"
  ok
}

cmd_toggle() {
  case "$(pget connectionstate)" in
    Disconnected|"") cmd_connect ;;
    *) cmd_disconnect ;;
  esac
}

cmd_set_region() {
  local id=${1-}
  [[ "$id" =~ ^[A-Za-z0-9_-]+$ ]] || fail "Invalid region"
  run_pia set region "$id" || fail "${LAST_MSG:-Could not change region}"
  ok
}

cmd_set() {
  local key=${1-} val=${2-}
  case "$key" in
    protocol) [[ "$val" == wireguard || "$val" == openvpn ]] || fail "Invalid protocol" ;;
    requestportforward|allowlan) [[ "$val" == true || "$val" == false ]] || fail "Invalid value" ;;
    *) fail "Unsupported setting" ;;
  esac
  run_pia set "$key" "$val" || fail "${LAST_MSG:-Could not change $key}"
  ok
}

# Long-lived: one status line whenever something changes (and a heartbeat
# every 30 s), polling fast while the tunnel is changing state.
cmd_watch() {
  local last="" line beat=0 delay
  while :; do
    line=$(cmd_status)
    if [[ "$line" != "$last" ]] || (( beat >= 30 )); then
      printf '%s\n' "$line"
      last=$line
      beat=0
    fi
    case "$line" in
      *'"state":"Connected"'*|*'"state":"Disconnected"'*) delay=3 ;;
      *'"daemon":false'*|*'"installed":false'*) delay=10 ;;
      *) delay=1 ;;
    esac
    sleep "$delay"
    beat=$((beat + delay))
    # Re-resolve: the client may have been installed while we were running.
    [[ -n "$PIA" && -x "$PIA" ]] || PIA=$(find_piactl) || PIA=""
  done
}

case "${1-status}" in
  watch|status) ;;
  *) need_pia ;;
esac

case "${1-status}" in
  watch)      cmd_watch ;;
  status)     cmd_status ;;
  regions)    cmd_regions ;;
  login)      cmd_login "${2-}" ;;
  logout)     cmd_logout ;;
  connect)    cmd_connect ;;
  disconnect) cmd_disconnect ;;
  toggle)     cmd_toggle ;;
  set-region) cmd_set_region "${2-}" ;;
  set)        cmd_set "${2-}" "${3-}" ;;
  *)          fail "Unknown command: $1" ;;
esac

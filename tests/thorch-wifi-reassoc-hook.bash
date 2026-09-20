#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hook="${root}/packages/thorch-bsp/payload/usr/lib/systemd/system-sleep/50-thorch-wifi-reassoc"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# Fake ip: empty FAKE_IP_LINK_OUTPUT means "no such device" (exit 1).
cat > "${tmp}/ip" <<'EOF'
#!/usr/bin/env bash
if [[ "${1}" == "link" && "${2}" == "show" ]]; then
  if [[ -z "${FAKE_IP_LINK_OUTPUT:-}" ]]; then
    exit 1
  fi
  printf '%s' "${FAKE_IP_LINK_OUTPUT}"
  exit 0
fi
echo "unexpected fake ip command: $*" >&2
exit 2
EOF
chmod 755 "${tmp}/ip"

# Fake nmcli: records calls.
cat > "${tmp}/nmcli" <<'EOF'
#!/usr/bin/env bash
echo "nmcli $*" >> "${FAKE_NMCLI_LOG:?}"
EOF
chmod 755 "${tmp}/nmcli"

# Fake systemctl: records calls.
cat > "${tmp}/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "${FAKE_SYSTEMCTL_LOG:?}"
EOF
chmod 755 "${tmp}/systemctl"

run_hook() {
  FAKE_IP_LINK_OUTPUT="${1}" \
  FAKE_NMCLI_LOG="${tmp}/nmcli.log" \
  FAKE_SYSTEMCTL_LOG="${tmp}/systemctl.log" \
  THORCH_WIFI_RETRY_DELAY=0 \
  THORCH_WIFI_RESCAN_DELAY=0 \
  PATH="${tmp}:${PATH}" \
    "${hook}" "${2:-post}" suspend s2idle
}

no_carrier="3: wlp1s0: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500 qdisc mq state DOWN mode DORMANT group default qlen 1000
"
healthy="3: wlp1s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP mode DORMANT group default qlen 1000
"

# Case 1: healthy (associated) WiFi -> no action.
: > "${tmp}/nmcli.log"; : > "${tmp}/systemctl.log"
run_hook "${healthy}"
[[ ! -s "${tmp}/nmcli.log" ]] || fail "nmcli called on healthy WiFi"
[[ ! -s "${tmp}/systemctl.log" ]] || fail "systemctl called on healthy WiFi"

# Case 2: NO-CARRIER after resume -> restart NetworkManager + rescan.
: > "${tmp}/nmcli.log"; : > "${tmp}/systemctl.log"
run_hook "${no_carrier}"
grep -qx 'systemctl restart NetworkManager' "${tmp}/systemctl.log" ||
  fail "NetworkManager not restarted on NO-CARRIER"
grep -qx 'nmcli device wifi rescan' "${tmp}/nmcli.log" ||
  fail "wifi rescan not triggered on NO-CARRIER"

# Case 3: no wlp1s0 on this system -> no action.
: > "${tmp}/nmcli.log"; : > "${tmp}/systemctl.log"
run_hook ""
[[ ! -s "${tmp}/nmcli.log" ]] || fail "nmcli called without wlp1s0"
[[ ! -s "${tmp}/systemctl.log" ]] || fail "systemctl called without wlp1s0"

# Case 4: pre (suspend) phase -> never acts.
: > "${tmp}/nmcli.log"; : > "${tmp}/systemctl.log"
run_hook "${no_carrier}" pre
[[ ! -s "${tmp}/nmcli.log" ]] || fail "nmcli called during pre phase"
[[ ! -s "${tmp}/systemctl.log" ]] || fail "systemctl called during pre phase"

printf 'thorch wifi reassoc hook checks passed\n'
#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hook="${root}/packages/thorch-bsp/payload/usr/lib/systemd/system-sleep/52-thorch-usb-reprobe"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# Fake sysfs tree. Root hubs usb1/usb2 have writable "authorized" files.
# Hub 1-1 (USB2 half of the dock) owns 1-1.2, hub 2-1 (USB3 half) owns
# 2-1.3. No "parent" symlinks: the real tree does not resolve them in the
# pre phase either, so the hook must derive parents from the address alone.
sys="${tmp}/sys"
dev="${sys}/bus/usb/devices"
hub1="${dev}/usb1"
hub2="${dev}/usb2"
for h in "${hub1}" "${hub2}"; do mkdir -p "${h}"; : > "${h}/authorized"; done
mkdir -p "${dev}/1-1" "${dev}/1-1.2" "${dev}/2-1" "${dev}/2-1.3"
: > "${dev}/1-1/authorized"
: > "${dev}/2-1/authorized"
: > "${dev}/1-1:1.0"   # interface dir: must be ignored by the snapshot

snap="${tmp}/snapshot"
: > "${snap}"

# Fake logger: records calls so we can assert the outcome hint.
cat > "${tmp}/logger" <<'EOF'
#!/usr/bin/env bash
echo "logger $*" >> "${FAKE_LOGGER_LOG:?}"
EOF
chmod 755 "${tmp}/logger"

# Fake sleep: records counts, no-op. A "restore_on" counter makes the Nth
# sleep re-create a missing device, simulating successful re-enumeration.
cat > "${tmp}/sleep" <<'EOF'
#!/usr/bin/env bash
sleep_count=$(( ${FAKE_SLEEP_COUNT:-0} + 1 ))
echo "${sleep_count}" > "${FAKE_SLEEP_COUNT_FILE:?}"
if [ -n "${FAKE_RESTORE_ON:-}" ] && [ "${sleep_count}" -eq "${FAKE_RESTORE_ON}" ]; then
  mkdir -p "${FAKE_RESTORE_PATH:?}"
  ln -sfn ../1-1 "${FAKE_RESTORE_PATH}/parent"
fi
exit 0
EOF
chmod 755 "${tmp}/sleep"

run_hook() {
  FAKE_LOGGER_LOG="${tmp}/logger.log" \
  FAKE_SLEEP_COUNT_FILE="${tmp}/sleep-count" \
  THORCH_USB_SYSFS_ROOT="${sys}" \
  THORCH_USB_SNAPSHOT_FILE="${snap}" \
  THORCH_USB_REPROBE_DELAY=0 \
  THORCH_USB_SETTLE_DELAY=0 \
  PATH="${tmp}:${PATH}" \
    "${hook}" "${1}" suspend s2idle
}

reset_state() {
  : > "${tmp}/logger.log"
  : > "${hub1}/authorized"
  : > "${hub2}/authorized"
  : > "${dev}/1-1/authorized" 2>/dev/null || true
  : > "${dev}/2-1/authorized"
  rm -rf "${dev}/1-1.2"
  mkdir -p "${dev}/1-1.2"
  ln -s ../1-1 "${dev}/1-1.2/parent"
  rm -f "${tmp}/sleep-count"
  unset FAKE_RESTORE_ON FAKE_RESTORE_PATH 2>/dev/null || true
}

assert_auth() {
  # $1 path, $2 expected content ("1" if cycled, "" if untouched)
  local got
  got="$(cat "${1}" 2>/dev/null || true)"
  [[ "${got}" == "${2}" ]] || fail "${1}: got '${got}', want '${2}'"
}

# Case 1: pre phase snapshots non-root, non-interface devices only.
reset_state
run_hook pre
grep -qx 'usb1	1-1' "${snap}" || fail "snapshot missing 1-1"
grep -qx '1-1	1-1.2' "${snap}" || fail "snapshot missing 1-1.2"
grep -qx 'usb2	2-1' "${snap}" || fail "snapshot missing 2-1"
grep -qx '2-1	2-1.3' "${snap}" || fail "snapshot missing 2-1.3"
if grep -q '1-1:1.0' "${snap}"; then fail "snapshot includes interface dir"; fi
if grep -q '	usb' "${snap}"; then fail "snapshot includes root hub"; fi

# Case 2: healthy resume — nothing missing -> no authorized writes.
reset_state
run_hook pre
run_hook post
assert_auth "${hub1}/authorized" ""
assert_auth "${hub2}/authorized" ""
assert_auth "${dev}/1-1/authorized" ""
assert_auth "${dev}/2-1/authorized" ""
[[ ! -s "${tmp}/logger.log" ]] || fail "logged while nothing missing"

# Case 3: one device vanishes (KB216-style) -> its parent hub cycles,
# and once re-enumeration brings it back the hook logs the recovery.
reset_state
run_hook pre
rm -rf "${dev}/1-1.2"
FAKE_RESTORE_ON=1 FAKE_RESTORE_PATH="${dev}/1-1.2" run_hook post
assert_auth "${dev}/1-1/authorized" "1"   # cycled
assert_auth "${hub1}/authorized" ""       # root hub untouched (parent still there)
assert_auth "${dev}/2-1/authorized" ""
grep -q 're-attached after resume' "${tmp}/logger.log" ||
  fail "recovery not logged"

# Case 4: parent hub itself gone (-108 variant) -> falls back to the bus
# root hub, which is the best software can do.
reset_state
run_hook pre
rm -rf "${dev}/1-1" "${dev}/1-1.2"
FAKE_RESTORE_PATH="${dev}/1-1" run_hook post
assert_auth "${hub1}/authorized" "1"      # root hub cycled as fallback
assert_auth "${dev}/2-1/authorized" ""
grep -q 'still missing after re-enumeration' "${tmp}/logger.log" ||
  fail "unrecoverable case not logged"
mkdir -p "${dev}/1-1"
: > "${dev}/1-1/authorized"
ln -s ../usb1 "${dev}/1-1/parent"

# Case 5: device removed before suspend (pre snapshot has no 1-1.2) ->
# hook must not chase it after resume.
reset_state
rm -rf "${dev}/1-1.2"   # gone before the pre snapshot
run_hook pre
run_hook post     # 1-1.2 absent from snapshot -> ignored
assert_auth "${hub1}/authorized" ""
assert_auth "${dev}/1-1/authorized" ""
assert_auth "${dev}/2-1/authorized" ""

# Case 6: no snapshot present -> no action.
reset_state
rm -f "${snap}"
run_hook post
assert_auth "${hub1}/authorized" ""
[[ ! -s "${tmp}/logger.log" ]] || fail "logged with no snapshot"

# Case 7: pre phase never acts on sysfs.
reset_state
run_hook pre
assert_auth "${hub1}/authorized" ""
assert_auth "${dev}/1-1/authorized" ""
assert_auth "${dev}/2-1/authorized" ""

printf 'thorch usb reprobe hook checks passed\n'
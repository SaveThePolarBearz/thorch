#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hook="${root}/packages/thorch-bsp/payload/usr/lib/systemd/system-sleep/51-thorch-touchscreen-reprobe"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# Fake sysfs tree: driver dir with both bound devices + writable unbind/bind.
sys="${tmp}/sys"
mkdir -p "${sys}/bus/i2c/drivers/edt_ft5x06/1-0038"
mkdir -p "${sys}/bus/i2c/drivers/edt_ft5x06/4-0038"
: > "${sys}/bus/i2c/drivers/edt_ft5x06/unbind"
: > "${sys}/bus/i2c/drivers/edt_ft5x06/bind"

# Fake cat: serves the debugfs num_x reads; empty FAKE_* var = read failure
# (debugfs unavailable).
cat > "${tmp}/cat" <<'EOF'
#!/usr/bin/env bash
case "${1}" in
  */i2c-4/4-0038/num_x)
    [[ -n "${FAKE_TOP_NUM_X:-}" ]] || exit 1
    printf '%s' "${FAKE_TOP_NUM_X}"
    exit 0
    ;;
  */i2c-1/1-0038/num_x)
    [[ -n "${FAKE_BOTTOM_NUM_X:-}" ]] || exit 1
    printf '%s' "${FAKE_BOTTOM_NUM_X}"
    exit 0
    ;;
  *)
    echo "unexpected fake cat: $*" >&2
    exit 2
    ;;
esac
EOF
chmod 755 "${tmp}/cat"

# Fake sleep: no-op so the test does not wait.
cat > "${tmp}/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "${tmp}/sleep"

run_hook() {
  FAKE_TOP_NUM_X="${1}" \
  FAKE_BOTTOM_NUM_X="${2}" \
  THORCH_TOUCH_SYSFS_ROOT="${sys}" \
  THORCH_TOUCH_REPROBE_DELAY=0 \
  PATH="${tmp}:${PATH}" \
    "${hook}" "${3:-post}" suspend s2idle
}

# Case 1: healthy registers (1080/1080) -> no unbind/bind.
: > "${sys}/bus/i2c/drivers/edt_ft5x06/unbind"
: > "${sys}/bus/i2c/drivers/edt_ft5x06/bind"
run_hook 1080 1080
[[ ! -s "${sys}/bus/i2c/drivers/edt_ft5x06/unbind" ]] ||
  fail "unbind written on healthy touchscreens"
[[ ! -s "${sys}/bus/i2c/drivers/edt_ft5x06/bind" ]] ||
  fail "bind written on healthy touchscreens"

# Case 2: corrupted registers (1024/1024) -> unbind/bind both devices.
: > "${sys}/bus/i2c/drivers/edt_ft5x06/unbind"
: > "${sys}/bus/i2c/drivers/edt_ft5x06/bind"
run_hook 1024 1024
grep -qx '4-0038' "${sys}/bus/i2c/drivers/edt_ft5x06/unbind" ||
  fail "unbind not written on corrupted touchscreens"
grep -qx '4-0038' "${sys}/bus/i2c/drivers/edt_ft5x06/bind" ||
  fail "bind not written on corrupted touchscreens"

# Case 3: only one screen corrupted -> still re-probes both.
: > "${sys}/bus/i2c/drivers/edt_ft5x06/unbind"
: > "${sys}/bus/i2c/drivers/edt_ft5x06/bind"
run_hook 1024 1080
grep -qx '4-0038' "${sys}/bus/i2c/drivers/edt_ft5x06/unbind" ||
  fail "unbind not written when only top screen corrupted"
grep -qx '4-0038' "${sys}/bus/i2c/drivers/edt_ft5x06/bind" ||
  fail "bind not written when only top screen corrupted"

# Case 4: debugfs unavailable (cat fails) -> re-probes anyway.
: > "${sys}/bus/i2c/drivers/edt_ft5x06/unbind"
: > "${sys}/bus/i2c/drivers/edt_ft5x06/bind"
run_hook "" ""
grep -qx '4-0038' "${sys}/bus/i2c/drivers/edt_ft5x06/unbind" ||
  fail "unbind not written when debugfs unavailable"
grep -qx '4-0038' "${sys}/bus/i2c/drivers/edt_ft5x06/bind" ||
  fail "bind not written when debugfs unavailable"

# Case 5: no touchscreens bound -> no action.
mv "${sys}/bus/i2c/drivers/edt_ft5x06/1-0038" "${tmp}/gone-1"
mv "${sys}/bus/i2c/drivers/edt_ft5x06/4-0038" "${tmp}/gone-4"
: > "${sys}/bus/i2c/drivers/edt_ft5x06/unbind"
: > "${sys}/bus/i2c/drivers/edt_ft5x06/bind"
run_hook 1024 1024
[[ ! -s "${sys}/bus/i2c/drivers/edt_ft5x06/unbind" ]] ||
  fail "unbind written without bound touchscreens"
[[ ! -s "${sys}/bus/i2c/drivers/edt_ft5x06/bind" ]] ||
  fail "bind written without bound touchscreens"
mv "${tmp}/gone-1" "${sys}/bus/i2c/drivers/edt_ft5x06/1-0038"
mv "${tmp}/gone-4" "${sys}/bus/i2c/drivers/edt_ft5x06/4-0038"

# Case 6: pre (suspend) phase -> never acts.
: > "${sys}/bus/i2c/drivers/edt_ft5x06/unbind"
: > "${sys}/bus/i2c/drivers/edt_ft5x06/bind"
run_hook 1024 1024 pre
[[ ! -s "${sys}/bus/i2c/drivers/edt_ft5x06/unbind" ]] ||
  fail "unbind written during pre phase"
[[ ! -s "${sys}/bus/i2c/drivers/edt_ft5x06/bind" ]] ||
  fail "bind written during pre phase"

printf 'thorch touchscreen reprobe hook checks passed\n'
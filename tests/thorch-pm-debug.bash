#!/usr/bin/env bash
# Behavioral tests for thorch-pm-debug, run against a fake sysfs tree via
# THORCH_PM_DEBUG_SYSFS_ROOT / THORCH_PM_DEBUG_DEBUGFS_ROOT so no root or real
# kernel knobs are required.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
thorch_pm_debug="${repo_root}/packages/thorch-bsp/payload/usr/bin/thorch-pm-debug"

failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

sysfs="${tmp}/sys"
debugfs="${tmp}/debug"
mkdir -p "${sysfs}/power" "${debugfs}/dynamic_debug"
: >"${debugfs}/dynamic_debug/control"

# Fake dynamic_debug/control that records writes.
cat >"${debugfs}/dynamic_debug/control" <<'EOF'
EOF

# Record the last write to the knob/dyndbg files.
pm_file="${sysfs}/power/pm_debug_messages"
dyn_file="${debugfs}/dynamic_debug/control"

expect_eq() {
  local desc="$1" got="$2" want="$3"
  if [[ "${got}" == "${want}" ]]; then
    printf 'ok - %s\n' "${desc}"
  else
    printf 'not ok - %s (got %q, want %q)\n' "${desc}" "${got}" "${want}"
    failures=$((failures + 1))
  fi
}

run() {
  THORCH_PM_DEBUG_SYSFS_ROOT="${sysfs}" \
    THORCH_PM_DEBUG_DEBUGFS_ROOT="${debugfs}" \
    THORCH_PM_DEBUG="${PM_SETTING:-0}" \
    "${thorch_pm_debug}" "$@"
}

# 1. Default (THORCH_PM_DEBUG unset/0): apply must NOT arm.
printf '0' >"${pm_file}"
PM_SETTING=0 run apply >/dev/null
expect_eq "apply with THORCH_PM_DEBUG=0 leaves knob at 0" "$(cat "${pm_file}")" "0"

# 2. Explicit on: apply arms the knob to 1 and enables dyndbg +p.
PM_SETTING=1 run apply >/dev/null
expect_eq "apply with THORCH_PM_DEBUG=1 sets knob to 1" "$(cat "${pm_file}")" "1"
expect_eq "apply enables pm_dev_dbg dyndbg +p" "$(cat "${dyn_file}")" "file drivers/base/power/main.c +p"

# 3. status reflects armed state.
PM_SETTING=1 run status >/dev/null
out="$(PM_SETTING=1 run status)"
expect_eq "status reports knob=1" "$(grep -c 'pm_debug_messages=1' <<<"${out}")" "1"

# 4. disarm turns the knob back off and removes dyndbg +p.
PM_SETTING=1 run disarm >/dev/null
expect_eq "disarm sets knob to 0" "$(cat "${pm_file}")" "0"
expect_eq "disarm writes dyndbg -p" "$(cat "${dyn_file}")" "file drivers/base/power/main.c -p"

# 5. Missing knob (kernel without CONFIG_PM_DEBUG): apply must not fail hard.
rm -f "${pm_file}"
if PM_SETTING=1 run apply >/dev/null 2>&1; then
  printf 'ok - apply tolerates missing pm_debug_messages knob\n'
else
  printf 'not ok - apply should tolerate missing knob\n'
  failures=$((failures + 1))
fi

# 6. Unknown subcommand exits 2.
if run bogus >/dev/null 2>&1; then
  printf 'not ok - bogus subcommand should fail\n'
  failures=$((failures + 1))
else
  rc=$?
  expect_eq "bogus subcommand exits 2" "${rc}" "2"
fi

if ((failures > 0)); then
  printf 'thorch pm-debug: %d check(s) failed\n' "${failures}" >&2
  exit 1
fi
printf 'thorch pm-debug checks passed\n'

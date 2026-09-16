#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${root}/packages/thorch-bsp/payload/usr/bin/thorch-fancontrol"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

run_fan() {
  THORCH_HARDWARE_CONFIG="${tmp}/hardware.conf" \
  THORCH_FAN_SYSFS_ROOT="${tmp}/sys" \
  THORCH_FAN_CONFIG= \
  THORCH_FAN_PWM_PATH= \
  THORCH_DEVICE_PWM_FAN= \
  DEVICE_PWM_FAN= \
  THORCH_FAN_TEMP_SENSORS= \
  THORCH_DEVICE_TEMP_SENSOR= \
  DEVICE_TEMP_SENSOR= \
    "${script}" "$@"
}

make_hwmon() {
  local dir="${tmp}/sys/class/hwmon/hwmon3"

  mkdir -p "${dir}"
  printf 'pwmfan\n' > "${dir}/name"
  printf '0\n' > "${dir}/pwm1"
  printf '0\n' > "${dir}/pwm1_enable"
}

make_zone() {
  local index="$1" type="$2" temp="$3" dir

  dir="${tmp}/sys/devices/virtual/thermal/thermal_zone${index}"
  mkdir -p "${dir}"
  printf '%s\n' "${type}" > "${dir}/type"
  printf '%s\n' "${temp}" > "${dir}/temp"
}

write_config() {
  local profile="$1" sensor_mode="${2:-max}"

  cat > "${tmp}/hardware.conf" <<EOF
THORCH_FAN_PROFILE=${profile}
THORCH_FAN_POLL_SECONDS=1
THORCH_FAN_SENSOR_MODE=${sensor_mode}
EOF
}

assert_file_value() {
  local path="$1" expected="$2" actual

  actual="$(< "${path}")"
  [[ "${actual}" == "${expected}" ]] || fail "${path} expected ${expected}, got ${actual}"
}

make_hwmon
make_zone 0 cpuss0-thermal 72000
make_zone 1 gpuss-0-thermal 84000
make_zone 2 pm8550-thermal 100000
make_zone 3 battery 100000

write_config moderate
run_fan once >/dev/null
assert_file_value "${tmp}/sys/class/hwmon/hwmon3/pwm1_enable" 1
assert_file_value "${tmp}/sys/class/hwmon/hwmon3/pwm1" 204

write_config quiet
run_fan once >/dev/null
assert_file_value "${tmp}/sys/class/hwmon/hwmon3/pwm1" 153

write_config aggressive
run_fan once >/dev/null
assert_file_value "${tmp}/sys/class/hwmon/hwmon3/pwm1" 255

write_config moderate average
run_fan once >/dev/null
assert_file_value "${tmp}/sys/class/hwmon/hwmon3/pwm1" 153

cat > "${tmp}/hardware.conf" <<EOF
THORCH_FAN_PROFILE=custom
THORCH_FAN_SENSOR_MODE=max
THORCH_FAN_TEMP_SENSORS="${tmp}/sys/devices/virtual/thermal/thermal_zone0/temp"
THORCH_FAN_T1=50000
THORCH_FAN_T2=60000
THORCH_FAN_T3=70000
THORCH_FAN_T4=80000
THORCH_FAN_T5=90000
THORCH_FAN_T6=95000
THORCH_FAN_MAX_TEMP=100000
THORCH_FAN_SPEED3=123
EOF
run_fan once >/dev/null
assert_file_value "${tmp}/sys/class/hwmon/hwmon3/pwm1" 123

status_output="$(run_fan status)"
grep -q '^profile: custom$' <<< "${status_output}" || fail "status did not report custom profile"
grep -q '^sensor_mode: max$' <<< "${status_output}" || fail "status did not report sensor mode"
grep -q '^target_pwm: 123$' <<< "${status_output}" || fail "status did not report target PWM"

rm -rf "${tmp}/sys/class/hwmon"
if run_fan once >/dev/null 2>&1; then
  fail "missing fan PWM unexpectedly succeeded"
fi

printf 'thorch-fancontrol fake sysfs tests passed\n'

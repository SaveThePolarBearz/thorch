#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fragment="${root}/packages/linux-thorch/waydroid-kernel.config"
build_script="${root}/scripts/build-thorch-kernel.sh"
driver_patch="${root}/packages/linux-thorch/patches/0300-mmc-add-qcom-downstream-sdhci-msm-driver.patch"
cleanup_patch="${root}/packages/linux-thorch/patches/0301-mmc-sdhci-msm-downstream-drop-sdhci_pltfm_free.patch"
clock_patch="${root}/packages/linux-thorch/patches/0302-Revert-clk-qcom-gcc-sm8550-Use-floor-ops-for-SDCC-RCGs.patch"
haptics_trace_patch="${root}/packages/linux-thorch/patches/0222-input-qcom-haptics-update-assign-str.patch"
retired_sdr104_patch="${root}/packages/linux-thorch/dts-patches/0007-arm64-dts-qcom-qcs8550-ayn-thor-enable-sdr104.patch"
gamepad_axis_patch="${root}/packages/linux-thorch/dts-patches/0007-arm64-dts-qcom-qcs8550-ayn-thor-set-gamepad-axis-range.patch"
haptics_erm_patch="${root}/packages/linux-thorch/dts-patches/0008-arm64-dts-qcom-qcs8550-ayn-thor-correct-haptics-lra-erm-flag.patch"
haptics_ff_stop_patch="${root}/packages/linux-thorch/patches/0225-input-qcom-haptics-fix-ff-stop-path.patch"
haptics_ff_perplay_stop_patch="${root}/packages/linux-thorch/patches/0226-input-qcom-haptics-arm-stop-per-ff-constant-play.patch"
haptics_ff_stop_rearm_patch="${root}/packages/linux-thorch/patches/0227-input-qcom-haptics-mod-delayed-work-per-play-stop.patch"
haptics_ff_rail_patch="${root}/packages/linux-thorch/patches/0228-input-qcom-haptics-restore-hpwr-vreg-per-play.patch"
haptics_lra_cal_patch="${root}/packages/linux-thorch/patches/0229-input-qcom-haptics-drop-lra-boot-cal-retries.patch"
haptics_sweep_log_patch="${root}/packages/linux-thorch/patches/0230-input-qcom-haptics-fix-hpwr-vreg-error-log-rc.patch"
haptics_brake_toggle_patch="${root}/packages/linux-thorch/patches/0231-input-qcom-haptics-drop-brake-poll-force-toggle.patch"
haptics_driver_base_patch="${root}/vendor/rocknix-sm8550/patches/linux/1000-add-qcom-haptics-driver.patch"
haptics_driver_sine_patch="${root}/vendor/rocknix-sm8550/patches/linux/1002-haptics-driver-support-periodic-sine-and-fixes.patch"
# Post-vendor-patch snapshot of the haptics driver, tracked so the Thor chain
# can be applied and asserted on in CI. CI never runs `make sync`, so without
# this the whole apply-based haptics suite below self-skipped and a green run
# proved nothing about these patches. See the README next to it.
haptics_driver_rel="drivers/input/misc/qcom-hv-haptics.c"
haptics_driver_fixture="${root}/tests/fixtures/linux-sm8550-haptics/${haptics_driver_rel}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for symbol in \
  UNICODE \
  DEBUG_INFO_BTF \
  SCHED_CLASS_EXT \
  FTRACE \
  FUNCTION_TRACER \
  DYNAMIC_FTRACE \
  KPROBES \
  KPROBE_EVENTS \
  UPROBE_EVENTS \
  PERF_EVENTS \
  BPF_EVENTS \
  CPU_FREQ_DEFAULT_GOV_SCHEDUTIL; do
  grep -qx "CONFIG_${symbol}=y" "${fragment}" ||
    fail "kernel fragment does not enable CONFIG_${symbol}"
done
grep -qx '# CONFIG_DEBUG_INFO_REDUCED is not set' "${fragment}" ||
  fail "kernel fragment leaves reduced debug info enabled"
grep -qx '# CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE is not set' "${fragment}" ||
  fail "kernel fragment leaves the performance governor as the default"

grep -q 'require_cmd .*pahole' "${build_script}" ||
  fail "kernel builder does not require pahole for BTF generation"
grep -q 'DYNAMIC_FTRACE_WITH_DIRECT_CALLS' "${build_script}" ||
  fail "kernel builder does not validate arm64 BPF trampoline support"
grep -q 'kernel patch or DTS inputs changed; rerun without --no-fetch' "${build_script}" ||
  fail "incremental kernel builds do not reject stale removed patches"
grep -q 'patch_input_digest="$(kernel_input_digest)"' "${build_script}" ||
  fail "kernel builder does not fingerprint its patch and DTS inputs"

for removed_patch in "${driver_patch}" "${cleanup_patch}" "${clock_patch}" "${retired_sdr104_patch}"; do
  [[ ! -e "${removed_patch}" ]] ||
    fail "retired SDR104 patch is still present: $(basename "${removed_patch}")"
done
! grep -q 'CONFIG_MMC_SDHCI_MSM_DOWNSTREAM' "${fragment}" ||
  fail "kernel fragment still enables the downstream SDHCI driver"
! grep -q 'MMC_SDHCI_MSM_DOWNSTREAM' "${build_script}" ||
  fail "kernel builder still requires the downstream SDHCI driver"
grep -q '__assign_str(id_name);' "${haptics_trace_patch}" ||
  fail "FTRACE-enabled Qualcomm haptics tracepoint fix is missing"
grep -Fq 'max-sd-hs-hz = <37500000>;' "${build_script}" ||
  fail "kernel builder does not enforce the 37.5 MHz board cap"
grep -Fq 'sdhci-caps-mask = <0x3 0x0>;' "${build_script}" ||
  fail "kernel builder does not enforce the unsupported UHS capability mask"
grep -Fq 'final ROCKNIX AYN DTS does not retain the 37.5 MHz SD clock cap' "${build_script}" ||
  fail "kernel builder does not fail when the board clock cap is absent"
grep -Fq 'final ROCKNIX AYN DTS does not mask unsupported UHS capabilities' "${build_script}" ||
  fail "kernel builder does not fail when the UHS capability mask is absent"
grep -Fq 'axis-range = <1024>;' "${gamepad_axis_patch}" ||
  fail "Thor DTS does not override the rsinput stick range to 1024 counts"
grep -Fq 'final ROCKNIX Thor DTS does not advertise the calibrated 1024-count stick range' "${build_script}" ||
  fail "kernel builder does not fail when the Thor stick range override is absent"
grep -Fq '/delete-property/ qcom,use-erm;' "${haptics_erm_patch}" ||
  fail "Thor DTS does not delete the haptics ERM flag for Thor's LRA"
grep -Fq 'qcom,use-erm = <0x00>;' "${haptics_erm_patch}" &&
  fail "Thor haptics patch re-sets the ERM flag to <0x00>, which of_property_read_bool still reads as set"
grep -Fq 'qcom,use-erm = <0x01>;' "${haptics_erm_patch}" &&
  fail "Thor haptics patch still leaves the ERM flag set"
grep -Fq '&pm8550b_hv_haptics {' "${haptics_erm_patch}" ||
  fail "Thor haptics patch does not override the shared AYN haptics node"
grep -Fq 'final ROCKNIX Thor DTS does not clear the haptics ERM flag' "${build_script}" ||
  fail "kernel builder does not fail when the Thor haptics ERM override is absent"
[[ -f "${haptics_ff_stop_patch}" ]] ||
  fail "Thor haptics FF stop-path fix is missing"
[[ -f "${haptics_ff_perplay_stop_patch}" ]] ||
  fail "Thor haptics per-play stop patch is missing"
[[ -f "${haptics_ff_stop_rearm_patch}" ]] ||
  fail "Thor haptics per-play stop re-arm patch is missing"
[[ -f "${haptics_ff_rail_patch}" ]] ||
  fail "Thor haptics per-play rail restore patch is missing"
[[ -f "${haptics_lra_cal_patch}" ]] ||
  fail "Thor haptics LRA calibration retry patch is missing"
[[ -f "${haptics_sweep_log_patch}" ]] ||
  fail "Thor haptics sweep_run_store rc log patch is missing"
[[ -f "${haptics_brake_toggle_patch}" ]] ||
  fail "Thor haptics brake poll force-toggle patch is missing"

# The FF stop-path fixes are verified against the real patched driver, not
# against the patch text. Grepping a diff cannot distinguish an applied hunk
# from its removal line or the commit message quoting the old code, and it
# cannot detect context drift that would break the patch at build time.
#
# The base is the tracked fixture rather than the gitignored vendor/ tree, so
# this runs in CI as well as locally. When vendor/ is present, apply the real
# vendor patches on top of the fixture and check the result still matches, so
# a fixture that has drifted from ROCKNIX is caught here too rather than at
# package build time.
[[ -f "${haptics_driver_fixture}" ]] ||
  fail "haptics driver fixture is missing: ${haptics_driver_fixture}"
haptics_scratch="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf -- '${haptics_scratch}'" EXIT
git -C "${haptics_scratch}" init -q .
mkdir -p "${haptics_scratch}/$(dirname -- "${haptics_driver_rel}")"
cp -- "${haptics_driver_fixture}" "${haptics_scratch}/${haptics_driver_rel}"
for patch in \
  "${haptics_ff_stop_patch}" \
  "${haptics_ff_perplay_stop_patch}" \
  "${haptics_ff_stop_rearm_patch}" \
  "${haptics_ff_rail_patch}" \
  "${haptics_lra_cal_patch}" \
  "${haptics_sweep_log_patch}" \
  "${haptics_brake_toggle_patch}"; do
  git -C "${haptics_scratch}" apply \
    --include="${haptics_driver_rel}" -- "${patch}" ||
    fail "haptics patch chain does not apply: ${patch}"
done
haptics_src="${haptics_scratch}/${haptics_driver_rel}"

if [[ -f "${haptics_driver_base_patch}" && -f "${haptics_driver_sine_patch}" ]]; then
  haptics_vendor_scratch="$(mktemp -d)"
  git -C "${haptics_vendor_scratch}" init -q .
  for patch in \
    "${haptics_driver_base_patch}" \
    "${haptics_driver_sine_patch}" \
    "${haptics_ff_stop_patch}" \
    "${haptics_ff_perplay_stop_patch}" \
    "${haptics_ff_stop_rearm_patch}" \
    "${haptics_ff_rail_patch}" \
    "${haptics_lra_cal_patch}" \
    "${haptics_sweep_log_patch}" \
    "${haptics_brake_toggle_patch}"; do
    git -C "${haptics_vendor_scratch}" apply \
      --include="${haptics_driver_rel}" -- "${patch}" ||
      fail "haptics patch chain does not apply against vendor: ${patch}"
  done
  diff -q "${haptics_vendor_scratch}/${haptics_driver_rel}" "${haptics_src}" >/dev/null ||
    fail "haptics fixture has drifted from the vendor driver tree; refresh tests/fixtures/linux-sm8550-haptics"
  rm -rf -- "${haptics_vendor_scratch}"
else
  printf 'NOTE: vendor/rocknix-sm8550 absent, skipped the fixture-drift cross-check\n'
fi

grep -Fq 'if (!val && chip->chip_is_playing)' "${haptics_src}" ||
  fail "patched haptics driver does not gate the stop on chip_is_playing"
grep -Fq 'return haptics_enable_play(chip, false);' "${haptics_src}" ||
  fail "patched haptics driver does not stop playback on a stop request"
grep -Fq 'chip->constant_replay_ms = length_ms;' "${haptics_src}" ||
  fail "patched haptics driver does not remember the constant replay length"
grep -Fq 'goto out_not_playing;' "${haptics_src}" ||
  fail "patched haptics driver does not clear chip_is_playing on a failed start"
# Every failure path in haptics_enable_play() must clear the flag, including
# the boost vreg one that 0226 missed.
if grep -A 3 -F 'Keep boost vreg on failed' "${haptics_src}" |
  grep -Fq 'return rc;'; then
  fail "patched haptics driver leaves chip_is_playing set on a boost vreg failure"
fi
# mod_delayed_work() needs the workqueue spelled out: unlike
# schedule_delayed_work() it has no implicit default, and
# INIT_DELAYED_WORK() binds none either. Two-arg mod_delayed_work()
# compiles to incompatible-pointer and too-few-arguments errors, so
# assert the full three-argument call. See 0227.
#
# The queue must be system_percpu_wq, which is what
# schedule_delayed_work() resolves to. system_wq is a deprecated alias
# marked "will be removed" in include/linux/workqueue.h, so name the
# queue the driver is actually meant to run on.
grep -Fq 'mod_delayed_work(system_percpu_wq, &chip->stop_work,' "${haptics_src}" ||
  fail "patched haptics driver does not pass system_percpu_wq to mod_delayed_work"
if grep -Fq 'mod_delayed_work(system_wq,' "${haptics_src}"; then
  fail "patched haptics driver uses the deprecated system_wq alias"
fi
if grep -Fq 'mod_delayed_work(&chip->stop_work,' "${haptics_src}"; then
  fail "patched haptics driver calls mod_delayed_work without a workqueue"
fi
# A %d conversion with no argument reads an uninitialised register on the
# variadic path, and a dev_err with no conversion at all hides rc entirely.
# Every hpwr_vreg failure site must report rc. See 0230.
if grep -Eq '(dev_err|dev_warn)\(chip->dev, "disable hpwr_vreg failed[^,]*"\)' "${haptics_src}"; then
  fail "patched haptics driver has a rail error log that does not report rc"
fi
if grep -F 'hpwr_vreg failed, rc=%d\n");' "${haptics_src}" | grep -q .; then
  fail "patched haptics driver has a %d with no argument in a rail error log"
fi
grep -Fq 'dev_err(chip->dev, "disable hpwr_vreg failed, rc=%d\n", rc);' "${haptics_src}" ||
  fail "patched haptics driver does not report rc in the sweep rail error log"
# The per-play stop work is the other rail-drop site and runs after every
# bounded play, so its failure log matters just as much.
grep -B 1 -Fq 'dev_err(chip->dev, "stop constant effect play failed");' "${haptics_src}" &&
  fail "patched haptics driver does not report rc when the per-play stop fails"
# The rail is dropped on every stop, so an upload-once/play-many client needs
# it restored per play. See 0228.
grep -Fq 'enable hpwr_vreg for play failed' "${haptics_src}" ||
  fail "patched haptics driver does not restore the haptics rail per play"
grep -A 2 -Fq 'haptics_enable_hpwr_vreg(chip, true);' "${haptics_src}" ||
  fail "patched haptics driver has no per-play hpwr_vreg enable"
# Play never started on the enable_play() failure path, so stop_work was
  # never armed and nothing would turn the rail back off. Assert the rail is
  # dropped again on that path or a persistently failing play leaves the rail
  # energized until an erase or teardown happens to run. See 0228.
  #
  # Scoped to haptics_playback() on purpose: the same enable_play() call
  # appears in the calibration and sweep helpers, and a whole-file grep with
  # -A would anchor on whichever comes first, which is not the path under test.
  haptics_playback_body="$(awk '/^static int haptics_playback\(/,/^}/' "${haptics_src}")"
  [[ -n "${haptics_playback_body}" ]] ||
    fail "patched haptics driver has no haptics_playback() to inspect"
  printf '%s\n' "${haptics_playback_body}" |
    grep -Fq 'haptics_enable_hpwr_vreg(chip, true);' ||
    fail "patched haptics driver does not restore the rail inside haptics_playback()"
  if ! printf '%s\n' "${haptics_playback_body}" |
    awk '/rc = haptics_enable_play\(chip, true\);/{f=1} f&&/haptics_enable_hpwr_vreg\(chip, false\);/{found=1} END{exit !found}'; then
    fail "patched haptics driver leaks the haptics rail when a play fails to start"
  fi
# On this board hBoost holds the rail at HPWR_READY, so the brake poll can
# never observe HPWR_DISABLED and always ran out its budget. Force-toggling
# HAPTICS_EN there power-cycled the block on most taps, which is what the
# alternating strength was. The recovery toggle must stay gated on a state
# that is neither HPWR_DISABLED nor HPWR_READY. See 0231.
brake_wait_body="$(awk '/^static int haptics_wait_brake_complete\(/,/^}/' "${haptics_src}")"
[[ -n "${brake_wait_body}" ]] ||
  fail "patched haptics driver has no haptics_wait_brake_complete() to inspect"
# The timeout branch must not toggle unconditionally. A bare
# `return haptics_toggle_module_enable(chip);` with no preceding status test
# is the bug, so require the guard on the same branch.
printf '%s\n' "${brake_wait_body}" |
  awk '/if \(timeout == 0\)/{f=1} f&&/!= HPWR_READY/{found=1} END{exit !found}' ||
  fail "patched haptics driver still force-toggles HAPTICS_EN when the rail is HPWR_READY"
# Accepting HPWR_READY as a completion signal would break out on the first
# poll and truncate the brake pattern on every stop.
if printf '%s\n' "${brake_wait_body}" |
  grep -Eq '\(val & HPWR_INTF_STATUS_MASK\) == HPWR_READY'; then
  fail "patched haptics driver treats HPWR_READY as brake complete"
fi
# A stale replay length after an erase would arm a stop timer sized for an
# effect that no longer exists.
grep -A 1 -F 'chip->chip_effect_loaded = false;' "${haptics_src}" |
  grep -Fq 'constant_replay_ms = 0;' ||
  fail "patched haptics driver leaves constant_replay_ms stale after an erase"
# Upload must not arm the stop timer any more; playback owns it now.
if grep -Fq 'schedule_delayed_work(&chip->stop_work, msecs_to_jiffies(length_ms));' \
  "${haptics_src}"; then
  fail "patched haptics driver still arms stop_work at upload time"
fi
# Each retry is a full-amplitude 150 ms direct play, and the Thor converges at
# 183 Hz on the first one, 2 Hz under the floor, so all three were discarded
# for the forced default. See 0229.
if grep -Fq 'while ((cl_f_lra < LRA_SPEC_MIN_FREQUENCY' "${haptics_src}"; then
  fail "patched haptics driver still retries the LRA boot calibration"
fi
# Dropping the retries must not change the frequency the motor runs at.
grep -Fq '"lra frequency detected at boot: %d Hz\n", cl_f_lra);' "${haptics_src}" ||
  fail "patched haptics driver no longer logs the SDAM boot LRA frequency"
grep -Fq 'haptics_config_openloop_lra_period(chip, LRA_SPEC_DEFAULT_PERIOD_US);' \
  "${haptics_src}" ||
  fail "patched haptics driver no longer forces the default LRA frequency"
grep -Fq 'chip->config.cl_t_lra_us = LRA_SPEC_DEFAULT_PERIOD_US;' "${haptics_src}" ||
  fail "patched haptics driver no longer stores the default LRA period"
# The sysfs calibration path still drives the actuator on demand.
grep -Fq 'rc = haptics_start_lra_calibrate(chip);' "${haptics_src}" ||
  fail "patched haptics driver dropped the sysfs LRA calibration entry point"

grep -q "printf 'THORCH_SD_DRIVER=upstream" "${build_script}" ||
  fail "kernel provenance does not identify the upstream SD driver"
grep -q "printf 'THORCH_SD_MAX_CLOCK_HZ=37500000" "${build_script}" ||
  fail "kernel provenance does not record the 37.5 MHz board cap"

printf 'thorch LAVD, SteamOS casefold, and upstream SD kernel checks passed\n'

# Update safety

Thorch does not currently publish a supported package feed. The repository can
build and test a local pacman repository, but that is a development input, not
a public update channel.

Installed updates must be complete `pacman -Syu` transactions. Partial upgrades
or direct replacement of individual package files are unsupported because the
kernel, modules, initramfs, boot payload, firmware, and userspace packages may
need to change together.

## Boot transaction

The `thorch-bsp` package installs libalpm hooks that:

1. retain the current `/boot/KERNEL`, initramfs, and matching modules before a
   transaction changes files;
2. rebuild and validate a candidate boot payload after the transaction; and
3. publish the candidate only after validation succeeds.

If rebuilding or validation fails, the retained boot files and modules are
restored. Pacman's package transaction may already be committed, so repository
rollback can still be required.

## Existing installations

Older images mask the stock mkinitcpio hooks and do not have the pre-transaction
retention hook. Upgrade `thorch-bsp` first, run `thorch-update-bootstrap`, and
confirm it reports ready before allowing the first kernel transaction. The
kernel package depends on the machine-local readiness marker so an
unbootstrapped direct upgrade fails before replacing the kernel.

`KERNEL.previous` is retained recovery material; automatic bootloader selection
of it has not been established. Keep tested SD recovery media available for
failed boots and power-loss recovery.

## Haptics ERM/LRA flag

`packages/linux-thorch/dts-patches/0008-arm64-dts-qcom-qcs8550-ayn-thor-correct-haptics-lra-erm-flag.patch`
overrides `qcom,use-erm` to `<0x00>` in the Thor board DTS. The shared AYN
`qcs8550-ayn-common.dtsi` still claims `<0x01>`, which is correct for no AYN
device that this change has been measured on except by omission, so the override
is board-scoped on purpose.

A false ERM claim does not fail loudly. The qcom-hv-haptics driver still accepts
every effect upload and play request, so evdev reports success and userspace
sees a working `/dev/input/eventN`, but the actuator is driven without LRA auto
resonance and without modulation and moves too little to feel. Treat "haptics
uploads succeed but nothing is felt" as a device-tree suspect, not a userspace
one.

Recovery: drop `0008-...` from
`packages/linux-thorch/dts-patches/`, rebuild the kernel, and flash. The change
is a single property in the Thor board file, touches no partition, boot payload,
or user data, and reverting it cannot brick the device. If the motor buzzes
incorrectly after the change, that revert is the first thing to try.

The build script validates the override in the final copied-and-patched DTS, so
a build with `0008` removed fails rather than silently shipping the silent-motor
configuration.

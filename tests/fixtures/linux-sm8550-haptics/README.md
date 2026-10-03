# Linux SM8550 haptics driver fixture

This is a snapshot of `drivers/input/misc/qcom-hv-haptics.c` as it exists
after the ROCKNIX vendor driver patches have been applied:

    1000-add-qcom-haptics-driver.patch
    1002-haptics-driver-support-periodic-sine-and-fixes.patch

It is **not** edited by anything in this repo. It exists so the Thor
haptics patch chain in `packages/linux-thorch/patches/0225` through `0230`
can be applied and asserted on in CI, which never runs `make sync` and so
never has the gitignored `vendor/rocknix-sm8550/` tree. Without this,
`tests/thorch-kernel-features.bash` skipped every behavioral haptics
assertion and a green CI run proved nothing about these patches.

The file is GPL-2.0-only, copyright The Linux Foundation and Qualcomm
Innovation Center. It is tracked in-tree only as test input, at the size
cost of roughly 160 KB, because a fixture is cheaper and more deterministic
than making CI clone ROCKNIX over the network.

## Refreshing it

When `ROCKNIX_REF` in `config/thorch.conf` moves, rebuild the snapshot from
the new vendor patches:

```sh
make sync
work="$(mktemp -d)"
cd "${work}" && git init -q .
mkdir -p drivers/input/misc
git apply --include='drivers/input/misc/qcom-hv-haptics.c' \
  vendor/rocknix-sm8550/patches/linux/1000-add-qcom-haptics-driver.patch
git apply --include='drivers/input/misc/qcom-hv-haptics.c' \
  vendor/rocknix-sm8550/patches/linux/1002-haptics-driver-support-periodic-sine-and-fixes.patch
cp drivers/input/misc/qcom-hv-haptics.c \
  tests/fixtures/linux-sm8550-haptics/drivers/input/misc/
```

Then run `bash tests/thorch-kernel-features.bash`. If the Thor chain no
longer applies, that is the intended signal: a context drift in the vendor
driver means the patches need refreshing, not the fixture.
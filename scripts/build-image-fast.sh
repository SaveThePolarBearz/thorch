#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${script_dir}/lib/common.sh"
load_thorch_config

usage() {
  cat >&2 <<'EOF'
usage: scripts/build-image-fast.sh [--with-kernel]

Fast rebuild path for Thorch image iteration. It rebuilds only missing/stale
local Thorch packages, refreshes build/image-rootfs when it exists, regenerates
boot artifacts, and reassembles the raw image.

If build/image-rootfs does not exist yet, it is created from the existing local
package repo after the missing/stale package refresh.

  --with-kernel   also rebuild linux-thorch; default skips it for userspace
                  package/default/service iterations.
EOF
}

with_kernel=0
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --with-kernel)
      with_kernel=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      die "unknown argument: $1"
      ;;
  esac
done

require_root

root="$(repo_root)"
build_dir="$(resolve_thorch_build_dir "${root}" "${THORCH_BUILD_DIR}")"
rootfs_dir="${build_dir}/image-rootfs"
repo_dir="${root}/${THORCH_LOCAL_REPO_DIR}"

rootfs_reusable() {
  [[ -x "${rootfs_dir}/usr/bin/pacman" && -d "${rootfs_dir}/var/lib/pacman" ]]
}

package_in_repo() {
  local pkg="$1" expected match pkgver
  local -a matches=()

  # Version-aware: an archive with the package name but a stale pkgver/pkgrel
  # must not satisfy the skip. Otherwise `make fast` would pair old installed
  # modules with a vendor kernel rebuilt for the new release.
  expected="$(python3 "${manifest_cli}" --repo "${root}" version "${pkg}")" || return 1
  [[ -n "${expected}" ]] || return 1

  shopt -s nullglob
  for match in "${repo_dir}/${pkg}-"*.pkg.tar.*; do
    [[ "${match}" != *.sig ]] || continue
    pkgver="$(bsdtar -xOqf "${match}" .PKGINFO 2>/dev/null |
      awk -F ' = ' '$1 == "pkgver" {print $2; exit}')"
    [[ "${pkgver}" == "${expected}" ]] && matches+=("${match}")
  done
  shopt -u nullglob
  [[ "${#matches[@]}" -gt 0 ]]
}

manifest_cli="${script_dir}/package-manifest.py"
if [[ -n "${THORCH_IMAGE_PACKAGES}" ]]; then
  read -r -a requested_image_packages <<< "${THORCH_IMAGE_PACKAGES}"
  requested_image_csv="$(IFS=,; printf '%s' "${requested_image_packages[*]}")"
  image_package_selection="$(
    python3 "${manifest_cli}" --repo "${root}" select \
      --profile image --packages "${requested_image_csv}"
  )"
else
  image_package_selection="$(
    python3 "${manifest_cli}" --repo "${root}" profile image
  )"
fi
[[ -n "${image_package_selection}" ]] || die "image package profile is empty"
mapfile -t image_packages <<< "${image_package_selection}"

packages_to_refresh=()
for pkg in "${image_packages[@]}"; do
  if [[ "${pkg}" == "linux-thorch" && "${with_kernel}" -eq 0 ]]; then
    if package_in_repo "${pkg}"; then
      log "skipping linux-thorch package refresh; ${repo_dir} already has the expected version (use --with-kernel to rebuild it)"
      continue
    fi
    warn "linux-thorch is stale or missing in ${repo_dir}; rebuilding it once so the image can be assembled"
  fi
  packages_to_refresh+=("${pkg}")
done

if [[ "${#packages_to_refresh[@]}" -gt 0 ]]; then
  image_packages_csv="$(IFS=,; printf '%s' "${packages_to_refresh[*]}")"
  "${script_dir}/build-packages.sh" --skip-fresh --packages "${image_packages_csv}"
else
  log "no local packages selected for refresh"
fi

if rootfs_reusable; then
  log "refreshing reusable rootfs ${rootfs_dir}"
  "${script_dir}/build-image.sh" --skip-package-build --reuse-rootfs
else
  log "creating reusable rootfs ${rootfs_dir} from local package repo"
  "${script_dir}/build-image.sh" --skip-package-build
fi

#!/usr/bin/env bash
# Behavioral test for build-image-fast.sh package_in_repo: a same-named but
# stale linux-thorch archive must not satisfy the skip, otherwise `make fast`
# can pair old installed modules with a vendor kernel rebuilt for a new pkgrel.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
builder="${root}/scripts/build-image-fast.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# Extract just the function under test; running the script would start a build.
eval "$(awk '/^package_in_repo\(\) \{/,/^\}/' "${builder}")"
type package_in_repo >/dev/null 2>&1 || fail "package_in_repo did not load"

# The manifest CLI is stubbed so the test is hermetic to the repo's pkgrel.
manifest_cli="${tmp}/manifest-stub"
cat > "${manifest_cli}" <<'EOF'
import sys

print("7.1.2-34")
EOF
chmod 755 "${manifest_cli}"

repo_dir="${tmp}/repo"
mkdir -p "${repo_dir}"

make_archive() {
  local version="$1" tree="${tmp}/tree"
  rm -rf "${tree}"
  mkdir -p "${tree}/usr/bin"
  printf 'pkgname = linux-thorch\npkgver = %s\narch = any\n' "${version}" > "${tree}/.PKGINFO"
  printf '#!/bin/sh\n' > "${tree}/usr/bin/linux-thorch-marker"
  bsdtar --uid 0 --gid 0 -cf "${repo_dir}/linux-thorch-${version}-any.pkg.tar.xz" \
    -C "${tree}" .
}

make_archive 7.1.2-33
if package_in_repo linux-thorch; then
  fail "stale linux-thorch archive satisfied the package skip"
fi

make_archive 7.1.2-34
package_in_repo linux-thorch ||
  fail "current linux-thorch archive was not recognized"

rm -f "${repo_dir}/linux-thorch-7.1.2-34-any.pkg.tar.xz"
if package_in_repo linux-thorch; then
  fail "missing linux-thorch archive satisfied the package skip"
fi

printf 'thorch image-fast package skip checks passed\n'

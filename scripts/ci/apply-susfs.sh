#!/usr/bin/env bash
# Apply simonpunk susfs4ksu kernel patches (gki-android12-5.10) to Melt marble.
# Mirrors the proven aosp-pablo flow: main patch + fs/ + include/ overlays.
set -euo pipefail

KERNEL_DIR="${KERNEL_DIR:-.}"
SUSFS_REPO="${SUSFS_REPO:-https://gitlab.com/simonpunk/susfs4ksu.git}"
SUSFS_KERNEL_BRANCH="${SUSFS_KERNEL_BRANCH:-gki-android12-5.10}"
SUSFS_COMMIT="${SUSFS_COMMIT:-f3b5aecf53ff8b3296603071b91383f6be6c7cbb}"

cd "${KERNEL_DIR}"
rm -rf susfs4ksu

echo "[+] Cloning susfs4ksu @ ${SUSFS_KERNEL_BRANCH}"
git clone --depth 40 --branch "${SUSFS_KERNEL_BRANCH}" "${SUSFS_REPO}" susfs4ksu
if [[ -n "${SUSFS_COMMIT}" ]]; then
  git -C susfs4ksu checkout "${SUSFS_COMMIT}"
fi
echo "[+] susfs4ksu: $(git -C susfs4ksu rev-parse HEAD) ($(git -C susfs4ksu log -1 --format=%s))"

patch_suffix="${SUSFS_KERNEL_BRANCH#gki-}"
main_patch="susfs4ksu/kernel_patches/50_add_susfs_in_gki-${patch_suffix}.patch"
if [[ ! -f "${main_patch}" ]]; then
  echo "::error::Missing main SUSFS patch ${main_patch}. Available:"
  ls susfs4ksu/kernel_patches/*.patch || true
  exit 1
fi

echo "[+] Applying ${main_patch}"
if ! patch -p1 --dry-run < "${main_patch}" >/dev/null 2>&1; then
  echo "::warning::dry-run failed, retrying with --fuzz=3"
  patch -p1 --fuzz=3 < "${main_patch}" || {
    echo "::error::SUSFS main patch failed. Rejects:"
    find . -name "*.rej" | head -20
    exit 1
  }
else
  patch -p1 < "${main_patch}"
fi

echo "[+] Syncing susfs fs/ + include/ overlays"
rsync -a susfs4ksu/kernel_patches/fs/ fs/
rsync -a susfs4ksu/kernel_patches/include/ include/

echo "[+] SUSFS kernel patches applied"

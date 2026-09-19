#!/usr/bin/env bash
# Add SukiSU-Ultra driver to the kernel tree (adapted from upstream setup.sh,
# made non-interactive + ref-pinned for CI).
set -euo pipefail

KERNEL_DIR="${KERNEL_DIR:-.}"
SUKISU_REPO="${SUKISU_REPO:-https://github.com/SukiSU-Ultra/SukiSU-Ultra.git}"
SUKISU_REF="${SUKISU_REF:-builtin}"

cd "${KERNEL_DIR}"

if [[ ! -d drivers ]]; then
  echo "::error::drivers/ directory not found in ${KERNEL_DIR}"
  exit 1
fi

# Idempotent cleanup of previous runs (fresh checkout shouldn't need it)
rm -f drivers/kernelsu
if [[ -d SukiSU-Ultra ]]; then
  rm -rf SukiSU-Ultra
fi

echo "[+] Cloning ${SUKISU_REPO} @ ${SUKISU_REF}"
if git ls-remote --heads "${SUKISU_REPO}" | grep -q "refs/heads/${SUKISU_REF}$"; then
  git clone --depth 1 --branch "${SUKISU_REF}" "${SUKISU_REPO}" SukiSU-Ultra
else
  # tag or commit sha
  git init SukiSU-Ultra
  git -C SukiSU-Ultra remote add origin "${SUKISU_REPO}"
  git -C SukiSU-Ultra fetch --depth 1 origin "${SUKISU_REF}"
  git -C SukiSU-Ultra checkout FETCH_HEAD
fi
echo "[+] SukiSU-Ultra: $(git -C SukiSU-Ultra rev-parse --short HEAD)"

# Same wiring as upstream setup.sh
ln -sf "$(realpath --relative-to=drivers SukiSU-Ultra/kernel)" drivers/kernelsu
grep -q "kernelsu" drivers/Makefile || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
grep -q 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig \
  || sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' drivers/Kconfig

echo "[+] SukiSU driver wired (drivers/kernelsu -> SukiSU-Ultra/kernel)"
grep -c "susfs" -ri SukiSU-Ultra/kernel --include="*.c" --include="*.h" --include="Kconfig" --include="Kbuild" --include="Makefile" 2>/dev/null \
  | awk -F: '{s+=$NF} END {print "[+] susfs references inside SukiSU driver: " (s+0)}' || true

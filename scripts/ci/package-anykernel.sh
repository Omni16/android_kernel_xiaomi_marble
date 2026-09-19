#!/usr/bin/env bash
# Pack Image + dtb/dtbo into an AnyKernel3 flashable zip.
set -euo pipefail

KERNEL_DIR="${KERNEL_DIR:-.}"
RELEASE_DIR="${KERNEL_DIR}/release"
ZIP_BASENAME="${ZIP_BASENAME:-Melt-SukiSU-marble}"
AK3_BRANCH="${AK3_BRANCH:-master}"

cd "${KERNEL_DIR}"
[[ -s release/Image ]] || { echo "::error::release/Image missing, build first"; exit 1; }

rm -rf AnyKernel3
git clone --depth 1 --branch "${AK3_BRANCH}" https://github.com/osm0sis/AnyKernel3 AnyKernel3

cp release/Image AnyKernel3/Image
[[ -s release/dtb ]] && cp release/dtb AnyKernel3/dtb
if [[ -s release/dtbo.img ]]; then
  cp release/dtbo.img AnyKernel3/dtbo.img
  sed -i 's/^do.dtbo=0/do.dtbo=1/' AnyKernel3/anykernel.sh
fi
sed -i "s|^kernel.string=.*|kernel.string=${ZIP_BASENAME} by github-actions|" AnyKernel3/anykernel.sh

rm -f AnyKernel3/.git* AnyKernel3/README.md 2>/dev/null || true
zip_name="${ZIP_BASENAME}.zip"
rm -f "release/${zip_name}"
(cd AnyKernel3 && zip -r9 "../release/${zip_name}" . -x ".git*" README.md)
echo "[+] packed release/${zip_name} ($(stat -c%s "release/${zip_name}") bytes)"

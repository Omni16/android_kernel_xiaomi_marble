#!/usr/bin/env bash
# Build Melt marble: marble_defconfig + DroidSpaces fragment + KSU/SUSFS toggles.
set -euo pipefail

KERNEL_DIR="${KERNEL_DIR:-.}"
ARCH="${ARCH:-arm64}"
OUT_DIR="${OUT_DIR:-out}"
RELEASE_DIR="${RELEASE_DIR:-release}"
DEFCONFIG="${DEFCONFIG:-marble_defconfig}"
DROIDSPACE_MODE="${DROIDSPACE_MODE:-full}"   # full | gki-safe | off
ENABLE_SUKISU="${ENABLE_SUKISU:-true}"
ENABLE_SUSFS="${ENABLE_SUSFS:-true}"
ENABLE_KPM="${ENABLE_KPM:-false}"
LTO="${LTO:-thin}"                            # thin | none
BUILD_MODULES="${BUILD_MODULES:-false}"
JOBS="${JOBS:-$(nproc)}"

if [[ "${ENABLE_SUSFS}" == "true" && "${ENABLE_SUKISU}" != "true" ]]; then
  echo "::error::ENABLE_SUSFS=true requires ENABLE_SUKISU=true"
  exit 1
fi

# Free runners (~7 GiB) OOM when linking vmlinux with full -j$(nproc): cap it.
if [[ -z "${JOBS_FORCE:-}" ]] && (( JOBS > 2 )); then
  echo "Capping JOBS ${JOBS} -> 2 (OOM-safe on free runners)"
  JOBS=2
fi

cd "${KERNEL_DIR}"
mkdir -p "${OUT_DIR}" "${RELEASE_DIR}"

export ARCH SUBARCH="${ARCH}"
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-melt-sukisu}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-github-actions}"
export CC="clang"

clang --version | tee "${RELEASE_DIR}/build.log"

echo "[+] defconfig: ${DEFCONFIG}" | tee -a "${RELEASE_DIR}/build.log"
make O="${OUT_DIR}" ARCH="${ARCH}" LLVM=1 LLVM_IAS=1 CC="${CC}" "${DEFCONFIG}" 2>&1 | tee -a "${RELEASE_DIR}/build.log"

case "${DROIDSPACE_MODE}" in
  full)     fragment="arch/${ARCH}/configs/fragments/droidspaces-full.config" ;;
  gki-safe) fragment="arch/${ARCH}/configs/fragments/droidspaces-gki-safe.config" ;;
  off)      fragment="" ;;
  *) echo "::error::Bad DROIDSPACE_MODE=${DROIDSPACE_MODE}"; exit 1 ;;
esac
if [[ -n "${fragment}" ]]; then
  [[ -f "${fragment}" ]] || { echo "::error::Missing fragment ${fragment}"; exit 1; }
  echo "[+] merging fragment ${fragment}" | tee -a "${RELEASE_DIR}/build.log"
  ./scripts/kconfig/merge_config.sh -O "${OUT_DIR}" -m "${OUT_DIR}/.config" "${fragment}" 2>&1 | tee -a "${RELEASE_DIR}/build.log"
fi

# Toggles (scripts/config is the permanent way: lands in .config, survives olddefconfig)
if [[ "${ENABLE_SUKISU}" == "true" ]]; then
  ./scripts/config --file "${OUT_DIR}/.config" -e KSU
  if [[ "${ENABLE_SUSFS}" == "true" ]]; then
    ./scripts/config --file "${OUT_DIR}/.config" -e KSU_SUSFS || echo "::warning::KSU_SUSFS symbol not found after patch"
  fi
  if [[ "${ENABLE_KPM}" == "true" ]]; then
    ./scripts/config --file "${OUT_DIR}/.config" -e KPM
  fi
else
  ./scripts/config --file "${OUT_DIR}/.config" -d KSU -d KSU_SUSFS -d KPM || true
fi

case "${LTO}" in
  none) ./scripts/config --file "${OUT_DIR}/.config" -d LTO_CLANG -d LTO_CLANG_THIN -d LTO_CLANG_FULL -e LTO_NONE || true ;;
  thin) ./scripts/config --file "${OUT_DIR}/.config" -d LTO_NONE -d LTO_CLANG_FULL -e LTO_CLANG -e LTO_CLANG_THIN || true ;;
  *) echo "::error::Bad LTO=${LTO}"; exit 1 ;;
esac

make O="${OUT_DIR}" ARCH="${ARCH}" LLVM=1 LLVM_IAS=1 CC="${CC}" olddefconfig 2>&1 | tee -a "${RELEASE_DIR}/build.log"

echo "=== final toggles ===" | tee -a "${RELEASE_DIR}/build.log"
grep -E "^CONFIG_KSU=y|# CONFIG_KSU is not set" "${OUT_DIR}/.config" | tee -a "${RELEASE_DIR}/build.log" || true
grep -E "^CONFIG_KSU_SUSFS=y|# CONFIG_KSU_SUSFS is not set" "${OUT_DIR}/.config" | tee -a "${RELEASE_DIR}/build.log" || true
grep -E "^CONFIG_USER_NS=y|# CONFIG_USER_NS is not set" "${OUT_DIR}/.config" | tee -a "${RELEASE_DIR}/build.log" || true
grep -cE "^CONFIG_(UTS_NS|NET_NS|SECCOMP|CGROUP_DEVICE|CGROUP_PIDS)=y" "${OUT_DIR}/.config" | tee -a "${RELEASE_DIR}/build.log"

if [[ "${ENABLE_SUKISU}" == "true" ]] && ! grep -q '^CONFIG_KSU=y$' "${OUT_DIR}/.config"; then
  echo "::error::CONFIG_KSU did not survive olddefconfig (KPROBES/EXT4_FS dependency?)"
  exit 1
fi

targets=(Image dtbs)
[[ "${BUILD_MODULES}" == "true" ]] && targets+=(modules)

if [[ "${LTO}" == "thin" ]]; then
  THINLTO_JOBS="${THINLTO_JOBS:-2}"
  THINLTO_CACHE_DIR="${THINLTO_CACHE_DIR:-${HOME}/.cache/thinlto}"
  mkdir -p "${THINLTO_CACHE_DIR}"
  wrapper="$(pwd)/${RELEASE_DIR}/ld-thinlto-wrapper"
  printf '#!/bin/bash\nexec ld.lld "$@" --thinlto-jobs=%s --thinlto-cache-dir=%q\n' \
    "${THINLTO_JOBS}" "${THINLTO_CACHE_DIR}" > "${wrapper}"
  chmod +x "${wrapper}"
  export LD="${wrapper}" HOSTLD="${wrapper}"
  echo "[+] ThinLTO jobs=${THINLTO_JOBS}" | tee -a "${RELEASE_DIR}/build.log"
fi

make -j"${JOBS}" O="${OUT_DIR}" ARCH="${ARCH}" LLVM=1 LLVM_IAS=1 CC="${CC}" "${targets[@]}" 2>&1 | tee -a "${RELEASE_DIR}/build.log"

image_path="${OUT_DIR}/arch/arm64/boot/Image"
[[ -s "${image_path}" ]] || { echo "::error::Image not built"; exit 1; }
(( $(stat -c%s "${image_path}") > 5000000 )) || { echo "::error::Image suspiciously small"; exit 1; }
file "${image_path}" | tee -a "${RELEASE_DIR}/build.log"
cp "${image_path}" "${RELEASE_DIR}/Image"

if find "${OUT_DIR}/arch/arm64/boot/dts" -name '*.dtb' -print -quit | grep -q .; then
  find "${OUT_DIR}/arch/arm64/boot/dts" -name '*.dtb' -exec cat {} + > "${RELEASE_DIR}/dtb"
  echo "[+] dtb: $(stat -c%s "${RELEASE_DIR}/dtb") bytes" | tee -a "${RELEASE_DIR}/build.log"
fi
if find "${OUT_DIR}/arch/arm64/boot/dts" -name '*.dtbo' -print -quit | grep -q .; then
  find "${OUT_DIR}/arch/arm64/boot/dts" -name '*.dtbo' -exec cat {} + > "${RELEASE_DIR}/dtbo.img"
  echo "[+] dtbo: $(stat -c%s "${RELEASE_DIR}/dtbo.img") bytes" | tee -a "${RELEASE_DIR}/build.log"
fi
if [[ "${BUILD_MODULES}" == "true" ]] && find "${OUT_DIR}" -name '*.ko' -print -quit | grep -q .; then
  find "${OUT_DIR}" -name '*.ko' -print0 | tar --null -T - -czf "${RELEASE_DIR}/modules.tar.gz"
fi

echo "[+] BUILD OK"

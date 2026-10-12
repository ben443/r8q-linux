#!/usr/bin/env bash
# Build the mainline kernel Image, modules, and r8q DTB.
# Usage: KSRC=/path/to/linux [OUT=/path/to/build] [BUSYBOX=/path/to/static-aarch64-busybox] ./scripts/build_kernel.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$REPO/out/kernel}"
JOBS="${JOBS:-$(nproc)}"
if [[ "$OUT" != /* ]]; then
    OUT="$PWD/$OUT"
fi

if [[ "${1:-}" == clean ]]; then
    rm -rf -- "$OUT"
    exit 0
fi

KSRC="${KSRC:-}"
if [[ -z "$KSRC" || ! -f "$KSRC/Makefile" ]]; then
    echo "Set KSRC to an existing mainline Linux source checkout." >&2
    exit 2
fi
KSRC="$(cd "$KSRC" && pwd)"

BUSYBOX="${BUSYBOX:-$REPO/initramfs/bin/busybox}"
if [[ ! -x "$BUSYBOX" ]]; then
    echo "Static AArch64 busybox is required at $BUSYBOX (or set BUSYBOX=/path/to/busybox)." >&2
    exit 2
fi

QCOM_DTS="$KSRC/arch/arm64/boot/dts/qcom"
MERGE_CONFIG="$KSRC/scripts/kconfig/merge_config.sh"
KCONFIG_SCRIPT="$KSRC/scripts/config"
for required in "$QCOM_DTS" "$MERGE_CONFIG" "$KCONFIG_SCRIPT"; do
    if [[ ! -e "$required" ]]; then
        echo "Kernel source is missing required build file: $required" >&2
        exit 2
    fi
done

mkdir -p "$OUT"
STAGED_INITRAMFS="$OUT/initramfs"
rm -rf -- "$STAGED_INITRAMFS"
mkdir -p "$STAGED_INITRAMFS/bin"
cp -a "$REPO/initramfs/." "$STAGED_INITRAMFS/"
install -m 0755 "$BUSYBOX" "$STAGED_INITRAMFS/bin/busybox"

install -m 0644 "$REPO/dts/sm8250-samsung-common.dtsi" "$QCOM_DTS/"
install -m 0644 "$REPO/dts/sm8250-samsung-r8q.dts" "$QCOM_DTS/"

cd "$KSRC"
for patch_file in "$REPO"/patches/*.patch; do
    if patch --batch --forward --dry-run -p1 < "$patch_file" >/dev/null 2>&1; then
        echo "Applying $(basename "$patch_file")"
        patch --batch --forward -p1 < "$patch_file"
    elif patch --batch --reverse --dry-run -p1 < "$patch_file" >/dev/null 2>&1; then
        echo "Already applied: $(basename "$patch_file")"
    else
        echo "Cannot apply or verify $(basename "$patch_file"); check the kernel version/source tree." >&2
        exit 1
    fi
done

make O="$OUT" ARCH=arm64 LLVM=1 defconfig
"$MERGE_CONFIG" -m -O "$OUT" "$OUT/.config" "$REPO/config/r8q_bringup.config"
"$KCONFIG_SCRIPT" --file "$OUT/.config" \
    --set-str CONFIG_CMDLINE "$(tr -d '\n' < "$REPO/config/cmdline.txt")" \
    --set-val CONFIG_CMDLINE_FORCE y \
    --set-str CONFIG_INITRAMFS_SOURCE "$STAGED_INITRAMFS $REPO/initramfs/irfs.devnodes"
make O="$OUT" ARCH=arm64 LLVM=1 olddefconfig

make O="$OUT" ARCH=arm64 LLVM=1 -j"$JOBS" Image dtbs modules

IMAGE="$OUT/arch/arm64/boot/Image"
DTB="$OUT/arch/arm64/boot/dts/qcom/sm8250-samsung-r8q.dtb"
for artifact in "$IMAGE" "$DTB"; do
    if [[ ! -s "$artifact" ]]; then
        echo "Expected kernel artifact was not produced: $artifact" >&2
        exit 1
    fi
done
echo "[+] Image: $IMAGE"
echo "[+] DTB:   $DTB"
echo "[+] Modules built; run make -C \"$KSRC\" O=\"$OUT\" ARCH=arm64 LLVM=1 INSTALL_MOD_PATH=... modules_install to install them."

#!/usr/bin/env bash
# Build the r8q kernel artifacts and, when MUSIL is set, the UEFI image.
# Usage: KSRC=/path/to/linux BUSYBOX=/path/to/static-aarch64-busybox [MUSIL=/path/to/Mu-Silicium] ./scripts/build.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KSRC="${KSRC:-}"
if [[ -z "$KSRC" ]]; then
    echo "Set KSRC to an existing mainline Linux source checkout." >&2
    exit 2
fi

KOUT="${KOUT:-$REPO/out/kernel}"
if [[ "$KOUT" != /* ]]; then
    KOUT="$PWD/$KOUT"
fi

KSRC="$KSRC" OUT="$KOUT" "${REPO}/scripts/build_kernel.sh"

if [[ -n "${MUSIL:-}" ]]; then
    MUSIL="$MUSIL" \
        DTB="$KOUT/arch/arm64/boot/dts/qcom/sm8250-samsung-r8q.dtb" \
        "${REPO}/scripts/build-uefi.sh"
else
    echo "[+] Kernel build complete. Set MUSIL=/path/to/Mu-Silicium to also build Mu-r8q-0.img."
fi

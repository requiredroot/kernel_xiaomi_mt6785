#!/bin/bash

set -euo pipefail

SECONDS=0

KERNEL_PATH="$PWD"
OUT_DIR="$KERNEL_PATH/out"
APATCH_OUT_DIR="$KERNEL_PATH/out-apatch"
AK3_DIR="$KERNEL_PATH/Anykernel"
DEFCONFIG="begonia_user_defconfig"
APATCH_DEFCONFIG="${DEFCONFIG%_defconfig}_apatch_defconfig"
CLANG_DIR="$KERNEL_PATH/clang"
CCACHE_DIR="$KERNEL_PATH/.ccache"
MKDTBOIMG="$KERNEL_PATH/.tools/mkdtboimg.py"

export LC_ALL=C
export ARCH=arm64
export KBUILD_BUILD_USER="Wahid7852"
export KBUILD_BUILD_HOST="NoVA"
export USE_HOST_LEX=yes

CC_CMD="clang"
HOSTCC_CMD="clang"
HOSTCXX_CMD="clang++"
if command -v ccache &>/dev/null; then
    export CCACHE_DIR
    ccache -M 20G &>/dev/null
    ccache -o base_dir="$KERNEL_PATH" &>/dev/null
    ccache -o sloppiness=file_macro,include_file_mtime,include_file_ctime &>/dev/null
    CC_CMD="ccache clang"
    HOSTCC_CMD="ccache clang"
    HOSTCXX_CMD="ccache clang++"
else
    echo "==> ccache not found, builds will not be cached (sudo pacman -S ccache to enable)"
fi

download_clang() {
    if [[ ! -d "$CLANG_DIR/bin" ]]; then
        echo "==> Downloading AOSP Clang..."

        wget -q \
        https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/tags/android-14.0.0_r50/clang-r510928.tar.gz \
        -O aosp-clang.tar.gz

        mkdir -p "$CLANG_DIR"
        tar -xf aosp-clang.tar.gz -C "$CLANG_DIR"
        rm -f aosp-clang.tar.gz
    fi
}

download_mkdtboimg() {
    if [[ ! -f "$MKDTBOIMG" ]]; then
        echo "==> Downloading mkdtboimg..."

        mkdir -p "$(dirname "$MKDTBOIMG")"
        wget -q -O - \
        "https://android.googlesource.com/platform/system/libufdt/+/refs/heads/main/utils/src/mkdtboimg.py?format=TEXT" \
        | base64 -d > "$MKDTBOIMG"

        if [[ ! -s "$MKDTBOIMG" ]]; then
            rm -f "$MKDTBOIMG"
            echo "Failed to download mkdtboimg!"
            exit 1
        fi
    fi
}

regen_defconfig() {
    local defconfig="${1:-$DEFCONFIG}"
    make O="$OUT_DIR" ARCH=arm64 "$defconfig" savedefconfig
    cp "$OUT_DIR/defconfig" "arch/arm64/configs/$defconfig"
}

_compile_and_package() {
    local out_dir="$1"
    local defconfig="$2"
    local revision="$3"

    download_clang

    export PATH="$CLANG_DIR/bin:$PATH"

    mkdir -p "$out_dir"
    rm -f "$out_dir/error.log"

    make O="$out_dir" ARCH=arm64 \
        HOSTCC="$HOSTCC_CMD" \
        HOSTCXX="$HOSTCXX_CMD" \
        "$defconfig"

    (
        exec 2> >(tee -a "$out_dir/error.log" >&2)
        make -j"$(nproc --all)" \
            O="$out_dir" \
            CC="$CC_CMD" \
            HOSTCC="$HOSTCC_CMD" \
            HOSTCXX="$HOSTCXX_CMD" \
            LLVM=1 \
            LLVM_IAS=1 \
            AR=llvm-ar \
            NM=llvm-nm \
            OBJCOPY=llvm-objcopy \
            OBJDUMP=llvm-objdump \
            STRIP=llvm-strip \
            LD=ld.lld \
            CROSS_COMPILE=aarch64-linux-gnu- \
            CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
    )

    DTS_DIR="$out_dir/arch/arm64/boot/dts/mediatek"
    KERNEL_IMG="$out_dir/arch/arm64/boot/Image.gz"
    KERNEL_DTB="$DTS_DIR/mt6785.dtb"

    if [[ ! -f "$KERNEL_IMG" ]]; then
        echo "Kernel image not found!"
        exit 1
    fi

    if [[ ! -f "$KERNEL_DTB" ]]; then
        echo "Kernel dtb not found!"
        exit 1
    fi

    # begonia.dtbo etc, packed into dtbo.img below
    mapfile -t KERNEL_DTBOS < <(find "$DTS_DIR" -maxdepth 1 -name '*.dtbo' | sort)

    if [[ ${#KERNEL_DTBOS[@]} -eq 0 ]]; then
        echo "Kernel dtbo not found!"
        exit 1
    fi

    SUBREV="4.14.$(grep 'SUBLEVEL =' Makefile | awk '{print $3}')"
    DATETIME="$(date +%Y%m%d-%H%M)"
    ZIPBASE="${revision}-${SUBREV}-${DATETIME}"
    ZIPNAME="${ZIPBASE}.zip"

    i=1
    while [[ -f "$ZIPNAME" ]]; do
        ZIPNAME="${ZIPBASE}_v${i}.zip"
        ((i++))
    done

    if [[ ! -d "$AK3_DIR" ]]; then
        git clone --depth=1 https://github.com/Wahid7852/Anykernel "$AK3_DIR"
    fi

    download_mkdtboimg

    rm -f "$AK3_DIR"/Image* "$AK3_DIR"/zImage* "$AK3_DIR"/*.dtb "$AK3_DIR"/*.dtbo \
          "$AK3_DIR/dtb" "$AK3_DIR/dtb.img" "$AK3_DIR/dtbo" "$AK3_DIR/dtbo.img"
    cp "$KERNEL_IMG" "$AK3_DIR/"
    cp "$KERNEL_DTB" "$AK3_DIR/dtb"

    python3 "$MKDTBOIMG" create "$AK3_DIR/dtbo.img" --page_size=2048 "${KERNEL_DTBOS[@]}"

    (
        cd "$AK3_DIR"
        git checkout master &>/dev/null || true
        zip -r9 "../$ZIPNAME" * -x .git README.md "*placeholder"
    )

    echo
    echo "Build complete: $ZIPNAME"
}

build_kernel() {
    _compile_and_package "$OUT_DIR" "$DEFCONFIG" "NoVA"
}

build_apatch() {
    _compile_and_package "$APATCH_OUT_DIR" "$APATCH_DEFCONFIG" "NoVA-APatch"
}

case "${1:-}" in
    -b|--build)
        rm -f ./NoVA-[0-9]*.zip
        build_kernel
        ;;
    -p|--build-apatch)
        rm -f ./NoVA-APatch-*.zip
        build_apatch
        ;;
    -a|--build-all)
        rm -f ./NoVA-[0-9]*.zip ./NoVA-APatch-*.zip
        build_kernel
        build_apatch
        ;;
    -r|--regen)
        regen_defconfig "${2:-}"
        ;;
    *)
        echo
        echo "Usage: $0 [option] [defconfig]"
        echo
        echo "  -b, --build         Build normal kernel"
        echo "  -p, --build-apatch  Build APatch-compatible kernel"
        echo "  -a, --build-all     Build both normal and APatch kernels"
        echo "  -r, --regen         Regenerate defconfig"
        exit 1
        ;;
esac

echo "Time: $((SECONDS / 60)) min $((SECONDS % 60)) sec"

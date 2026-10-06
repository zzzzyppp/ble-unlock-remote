#!/usr/bin/env bash
#
# 生成介绍视频（1080p H.264 MP4，中英双版）。
#
# 流程：渲染 PNG 序列 -> 编码 MP4。
# 编码用 macOS 自带的 AVFoundation，不需要 ffmpeg。
#
# 用法:
#   ./build-video.sh              # 中英双版
#   ./build-video.sh zh           # 只做中文
#   ./build-video.sh --fps 60     # 换帧率

set -euo pipefail

cd "$(dirname "$0")"

FPS=30
LANGS=(zh en)
while [ $# -gt 0 ]; do
    case "$1" in
        --fps) FPS="$2"; shift 2 ;;
        zh|en) LANGS=("$1"); shift ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done

# 优先用 DSH 自带 Python（Pillow 齐全），否则退回系统 python3
PY="${DSH_PYTHON:-}"
if [ -z "$PY" ]; then
    for c in \
        "$HOME/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/bin/python3" \
        "$(command -v python3 2>/dev/null || true)"; do
        if [ -n "$c" ] && [ -x "$c" ] && "$c" -c 'import PIL' >/dev/null 2>&1; then
            PY="$c"; break
        fi
    done
fi
if [ -z "$PY" ]; then
    echo "✗ 找不到带 Pillow 的 Python" >&2
    exit 1
fi

# 编码器按需编译
ENCODER="build/encode-video"
if [ ! -x "$ENCODER" ] || [ tools/encode-video.swift -nt "$ENCODER" ]; then
    echo "==> 编译视频编码器"
    mkdir -p build
    swiftc -O -suppress-warnings -module-cache-path "$PWD/.cache" \
        -target arm64-apple-macos11.0 tools/encode-video.swift -o "$ENCODER"
fi

mkdir -p docs
for lang in "${LANGS[@]}"; do
    frames="build/frames-$lang"
    echo "==> 渲染 $lang 的 PNG 序列（1920x1080 @ ${FPS}fps）"
    rm -rf "$frames"
    "$PY" tools/make-demo-gif.py --lang "$lang" --resolution 1920x1080 \
        --fps "$FPS" --export-png "$frames" >/dev/null

    echo "==> 编码 $lang MP4"
    "$ENCODER" "$frames" "docs/demo-$lang.mp4" --fps "$FPS"
    rm -rf "$frames"
done

echo
echo "✓ 完成"
ls -lh docs/*.mp4 | awk '{printf "  %-26s %s\n", $9, $5}'

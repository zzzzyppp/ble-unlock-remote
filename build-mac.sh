#!/bin/bash
# 把 mac-src/main.swift 以 base64 形式嵌入 template.sh，生成自包含的 mac-ble-unlock.sh
set -euo pipefail

cd "$(dirname "$0")"

if [ ! -f mac-src/main.swift ]; then
    echo "找不到 mac-src/main.swift" >&2
    exit 1
fi
if [ ! -f template.sh ]; then
    echo "找不到 template.sh" >&2
    exit 1
fi

# 去掉模板中原本的内嵌区段（如果有），再追加新的
awk '/^__SWIFT_SOURCE_BELOW__$/{exit} {print}' template.sh > mac-ble-unlock.sh

{
    echo "__SWIFT_SOURCE_BELOW__"
    base64 < mac-src/main.swift
    echo "__SWIFT_SOURCE_END__"
} >> mac-ble-unlock.sh

chmod 755 mac-ble-unlock.sh

echo "已生成 mac-ble-unlock.sh ($(wc -l < mac-ble-unlock.sh | tr -d ' ') 行)"
echo "语法检查:"
bash -n mac-ble-unlock.sh && echo "  OK"

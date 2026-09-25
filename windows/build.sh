#!/bin/sh
# Cross-compiles KVMSwitcher.exe (x64, no runtime dependencies) from macOS or Linux.
# Needs mingw-w64: `brew install mingw-w64` or `apt-get install gcc-mingw-w64-x86-64`.
set -eu
cd "$(dirname "$0")"
x86_64-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -municode -mwindows -static -s \
  kvm_switcher.c -o KVMSwitcher.exe \
  -ldxva2 -lsetupapi -lshlwapi -lshell32 -luser32 -ladvapi32
echo "Built $(pwd)/KVMSwitcher.exe ($(wc -c < KVMSwitcher.exe | tr -d ' ') bytes)"

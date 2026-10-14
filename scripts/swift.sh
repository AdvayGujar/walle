#!/usr/bin/env bash
# Build wrapper for walle.
#
# 1. Keeps every SwiftPM and clang cache inside the repository, because a
#    workspace-write sandbox forbids writes to ~/Library and to the shared
#    system module cache.
# 2. Passes --disable-sandbox because SwiftPM wraps manifest compilation in
#    sandbox-exec, which cannot nest inside an outer sandbox
#    ("sandbox_apply: Operation not permitted").
#
# Both are harmless outside a sandbox.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/modulecache .build/cache .build/scratch
export CLANG_MODULE_CACHE_PATH="$PWD/.build/modulecache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/modulecache"
export SWIFTPM_CONFIG_PATH="$PWD/.build/config"
exec swift "$@" --scratch-path "$PWD/.build/scratch" --cache-path "$PWD/.build/cache" --disable-sandbox

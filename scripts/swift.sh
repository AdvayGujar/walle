#!/usr/bin/env bash
# Build wrapper for walle. Use this for every build and test.
#
# 1. Keeps SwiftPM and clang caches inside the repository, because a workspace-write
#    sandbox forbids writes to ~/Library and to the shared system module cache.
# 2. Passes --disable-sandbox because SwiftPM wraps manifest compilation in
#    sandbox-exec, which cannot nest inside an outer sandbox
#    ("sandbox_apply: Operation not permitted").
# 3. WALLE_SWIFT_TAG isolates scratch, cache and module-cache directories so several
#    agents can build concurrently without fighting over one .build/scratch.
#
# All of this is harmless outside a sandbox.
set -eo pipefail
cd "$(dirname "$0")/.."

TAG=$WALLE_SWIFT_TAG
SCRATCH="$PWD/.build/scratch$TAG"
CACHE="$PWD/.build/cache$TAG"
MODULECACHE="$PWD/.build/modulecache$TAG"
mkdir -p "$SCRATCH" "$CACHE" "$MODULECACHE"

export CLANG_MODULE_CACHE_PATH="$MODULECACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULECACHE"
export SWIFTPM_CONFIG_PATH="$PWD/.build/config"

exec swift "$@" --scratch-path "$SCRATCH" --cache-path "$CACHE" --disable-sandbox

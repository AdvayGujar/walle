#!/usr/bin/env bash
# Reclaim disk space.
#
# .build is 100% regenerable SwiftPM output and is where nearly all of walle's
# on-disk size goes: a release build is about 109 MB of intermediates, and adding
# the test build takes it to roughly 242 MB. The project's actual source is 176 KB.
#
# Deleting it is always safe. The next ./scripts/swift.sh build recreates it.
set -eo pipefail
cd "$(dirname "$0")/.."
rm -rf .build
echo "removed .build"
du -sh . | awk '{print "project now: " $1}'

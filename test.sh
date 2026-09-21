#!/bin/zsh
set -eu
cd "${0:A:h}"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/usagebar-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
printf '%s\n' 'import Foundation' 'runTests()' > "$test_dir/main.swift"
# Keep assertions enabled independently of the optimized application build.
swiftc -Onone -swift-version 5 Sources/UsageModel.swift "$test_dir/main.swift" -o "$test_dir/UsageBarTests"
"$test_dir/UsageBarTests"

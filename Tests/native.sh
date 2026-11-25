#!/bin/zsh
set -euo pipefail
setopt extendedglob
cd "${0:A:h:h}"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
cp Tests/fixtures/exercise.{png,pdf} "$scratch/"
swiftc -swift-version 5 Sources/*.swift~Sources/main.swift Tests/Smoke.swift -o "$scratch/smoke"
GRIDNOTE_DEMO="$PWD/docs/examples/Series circuit.gridnote" "$scratch/smoke" "$scratch"
swiftc -swift-version 5 Sources/*.swift~Sources/main.swift Tests/Crash.swift -o "$scratch/crash"
"$scratch/crash" edit "$scratch/crash-session" &
writer=$!
for attempt in {1..80}; do
  [[ -f "$scratch/crash-session/ready" ]] && break
  sleep .1
done
[[ -f "$scratch/crash-session/ready" ]]
kill -KILL "$writer"
wait "$writer" 2>/dev/null || true
"$scratch/crash" verify "$scratch/crash-session"

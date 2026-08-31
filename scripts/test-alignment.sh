#!/usr/bin/env bash
# Runs the ScriptAlignmentEngine scenarios headlessly on a Mac — no simulator,
# no device, no Xcode test target. Alignment is pure data in / data out, so it
# can be verified directly by compiling the Domain + engine sources.
#
#   ./scripts/test-alignment.sh
#
# Exits non-zero if any scenario fails, so it also works as a CI gate.
set -euo pipefail

cd "$(dirname "$0")/.."
IOS="ios/Pollux One"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# -default-isolation MainActor matches the app target's build setting, so the
# engine compiles under the same actor rules it ships with.
swiftc -O -swift-version 5 -default-isolation MainActor \
  "$IOS/Domain/ScriptModels.swift" \
  "$IOS/Domain/CameraConfiguration.swift" \
  "$IOS/Domain/SessionModels.swift" \
  "$IOS/Domain/SpeechTranscript.swift" \
  "$IOS/Domain/SentenceSplitter.swift" \
  "$IOS/Domain/TextTokenizer.swift" \
  "$IOS/Engines/ScriptAlignmentEngine.swift" \
  "ios/AlignmentHarness/main.swift" \
  -o "$OUT/alignment_harness"

# Run once, show everything, then gate on the summary line the harness prints.
"$OUT/alignment_harness" | tee "$OUT/results.txt"

if grep -qE "TOTAL: [0-9]+ passed, 0 failed" "$OUT/results.txt"; then
  exit 0
fi
echo "alignment scenarios failed" >&2
exit 1

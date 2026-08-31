#!/usr/bin/env bash
# Runs the reading-following and safe-word/voice-command scenarios headlessly
# on a Mac — no simulator, no device, no Xcode test target. Both pipelines are
# pure data in / data out, so they can be verified by compiling the Domain +
# engine sources directly.
#
#   ./scripts/test-engines.sh
#
# Exits non-zero if any scenario fails, so it also works as a CI gate.
set -euo pipefail

cd "$(dirname "$0")/.."
IOS="ios/Pollux One"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# -default-isolation MainActor matches the app target's build setting, so the
# engines compile under the same actor rules they ship with.
swiftc -O -swift-version 5 -default-isolation MainActor \
  "$IOS/Domain/ScriptModels.swift" \
  "$IOS/Domain/CameraConfiguration.swift" \
  "$IOS/Domain/SessionModels.swift" \
  "$IOS/Domain/SpeechTranscript.swift" \
  "$IOS/Domain/SentenceSplitter.swift" \
  "$IOS/Domain/ScriptLanguage.swift" \
  "$IOS/Domain/PromptScriptText.swift" \
  "$IOS/Domain/PromptLineLayout.swift" \
  "$IOS/Domain/TextTokenizer.swift" \
  "$IOS/Domain/VoiceCommand.swift" \
  "$IOS/Domain/TakeArchive.swift" \
  "$IOS/Engines/ScriptAlignmentEngine.swift" \
  "$IOS/Engines/ReadingPacer.swift" \
  "$IOS/Engines/SafeWordDetector.swift" \
  "$IOS/Engines/VoiceCommandEngine.swift" \
  "$IOS/Engines/TakeArchiver.swift" \
  ios/EngineHarness/Harness.swift \
  ios/EngineHarness/FakeTextMeasurer.swift \
  ios/EngineHarness/AlignmentScenarios.swift \
  ios/EngineHarness/VoiceScenarios.swift \
  ios/EngineHarness/CameraScenarios.swift \
  ios/EngineHarness/ArchiveScenarios.swift \
  ios/EngineHarness/LayoutScenarios.swift \
  ios/EngineHarness/PacingScenarios.swift \
  ios/EngineHarness/main.swift \
  -o "$OUT/engine_harness"

# Run once, show everything, then gate on the summary line the harness prints.
"$OUT/engine_harness" | tee "$OUT/results.txt"

if grep -qE "TOTAL: [0-9]+ passed, 0 failed" "$OUT/results.txt"; then
  exit 0
fi
echo "engine scenarios failed" >&2
exit 1

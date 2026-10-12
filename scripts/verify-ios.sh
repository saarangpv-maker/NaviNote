#!/bin/zsh
# Full iOS checkpoint: clean Debug and Release builds (simulator), a
# Release build for devices, and every unit and UI test, counting compiler
# warnings. Usage: scripts/verify-ios.sh [work-dir]   (default: /tmp/navinote-verify)
set -u
cd "$(dirname "$0")/.."
WORK="${1:-/tmp/navinote-verify}"
mkdir -p "$WORK"
OUT="$WORK/summary.txt"; : > "$OUT"
D='platform=iOS Simulator,name=iPhone 17e'
w() { grep -E ': warning:' "$1" | sort -u | wc -l | tr -d ' '; }
step() { echo "== $1" | tee -a "$OUT"; }

step "Clean Debug build (simulator)"
xcodebuild -project NaviNote.xcodeproj -scheme NaviNote -configuration Debug -destination "$D" -derivedDataPath "$WORK/DD" clean build > "$WORK/debug.log" 2>&1
echo "exit $? warnings: $(w "$WORK/debug.log")" | tee -a "$OUT"

step "Clean Release build (simulator)"
xcodebuild -project NaviNote.xcodeproj -scheme NaviNote -configuration Release -destination "$D" -derivedDataPath "$WORK/DDR" clean build > "$WORK/release.log" 2>&1
echo "exit $? warnings: $(w "$WORK/release.log")" | tee -a "$OUT"

step "Release build (generic device)"
xcodebuild -project NaviNote.xcodeproj -scheme NaviNote -configuration Release -destination 'generic/platform=iOS' -derivedDataPath "$WORK/DDR" CODE_SIGNING_ALLOWED=NO build > "$WORK/release-device.log" 2>&1
echo "exit $? warnings: $(w "$WORK/release-device.log")" | tee -a "$OUT"

step "Release bundle check"
scripts/check-release-app.sh "$WORK/DDR/Build/Products/Release-iphoneos/NaviNote.app" | tail -1 | tee -a "$OUT"

step "All tests (unit + UI)"
rm -rf "$WORK/tests.xcresult"
xcodebuild -project NaviNote.xcodeproj -scheme NaviNote -destination "$D" -derivedDataPath "$WORK/DD" -resultBundlePath "$WORK/tests.xcresult" test > "$WORK/test.log" 2>&1
echo "exit $?" | tee -a "$OUT"
echo "compiler warnings: $(w "$WORK/test.log")" | tee -a "$OUT"
echo "unit passed: $(grep -cE "^Test case '.*' passed" "$WORK/test.log") failed: $(grep -cE "^Test case '.*' failed" "$WORK/test.log")" | tee -a "$OUT"
echo "UI passed: $(grep -cE "Test Case '-\[NaviNoteUITests.* passed" "$WORK/test.log") failed: $(grep -cE "Test Case '-\[NaviNoteUITests.* failed" "$WORK/test.log")" | tee -a "$OUT"
grep -E "^Test case '.*' failed|Test Case '.*' failed" "$WORK/test.log" | head -20 | tee -a "$OUT"
echo "ALL DONE" | tee -a "$OUT"

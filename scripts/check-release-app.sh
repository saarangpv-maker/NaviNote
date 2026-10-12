#!/bin/zsh
# Verifies a built Release NaviNote.app contains no API key, no local
# development address and no Debug-only security exception.
#   scripts/check-release-app.sh path/to/Release-iphoneos/NaviNote.app
set -u
app="${1:?usage: check-release-app.sh <NaviNote.app>}"
plist="$app/Info.plist"
binary="$app/NaviNote"
failures=0
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }
pass() { echo "ok:   $1"; }

[[ -f "$plist" && -f "$binary" ]] || { echo "Not an app bundle: $app"; exit 2; }

if plutil -extract NSAppTransportSecurity raw -o - "$plist" >/dev/null 2>&1; then
  fail "Info.plist has NSAppTransportSecurity (Debug-only exception)"
else pass "no App Transport Security exception"; fi

if plutil -extract NSLocalNetworkUsageDescription raw -o - "$plist" >/dev/null 2>&1; then
  fail "Info.plist has NSLocalNetworkUsageDescription (Debug-only)"
else pass "no local-network usage description"; fi

url=$(plutil -extract NaviNoteAstraBaseURL raw -o - "$plist" 2>/dev/null || echo "")
if [[ -z "$url" ]]; then pass "Astra URL empty (no production host yet)"
elif [[ "$url" == https://* && "$url" != *.local* && "$url" != *localhost* ]]; then pass "Astra URL is HTTPS"
else fail "Astra URL is not a production HTTPS URL: $url"; fi

# The executable must not contain development hosts (the Debug-only
# local-address check is compiled out of Release).
for needle in ".local:" "localhost" "127.0.0.1" "192.168." "NSAllowsLocalNetworking"; do
  if strings -a "$binary" | grep -qF -- "$needle"; then fail "executable contains \"$needle\""
  else pass "executable has no \"$needle\""; fi
done

# No credentials anywhere in the bundle.
if node "$(dirname "$0")/secret-scan.mjs" "$app" >/dev/null 2>&1; then pass "secret scan of the bundle"
else fail "secret scan of the bundle"; node "$(dirname "$0")/secret-scan.mjs" "$app"; fi

if (( failures > 0 )); then echo "Release check FAILED ($failures)"; exit 1; fi
echo "Release check passed."

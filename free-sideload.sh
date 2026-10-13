#!/bin/bash
# free-sideload.sh <app.ipa> — install IPA with a free Apple ID, no servers.
# Requires: macOS + Xcode with logged-in Apple ID + iPhone on USB or Wi-Fi.
# Usage: /bin/bash free-sideload.sh /path/to/app.ipa
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEVICECTL=/usr/bin/xcrun

fail() { echo "ERROR: $*" >&2; exit "${2:-1}"; }
info() { echo "==> $*"; }

if [ $# -eq 0 ]; then
  echo "Please specify the .ipa path (relative or absolute) — or drag & drop the .ipa file into this window and press Enter."
  printf "IPA path: "; IFS= read -r IPA_IN || exit 2
  IPA="$(echo "$IPA_IN" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//")"
  IPA="${IPA//\\ / }"
  [ -n "$IPA" ] || exit 2
  set --
elif [ -f "$1" ]; then
  IPA="$1"; shift
else
  IPA="$*"; set --
fi
STRIP_WATCH=1
for A in "$@"; do
  case "$A" in
    --keep-watch) STRIP_WATCH=0 ;;
    *) fail "Unknown option: $A (usage: $0 <app.ipa> [--keep-watch])" ;;
  esac
done
[ -f "$IPA" ] || fail "No such file: $IPA"
command -v xcodebuild >/dev/null 2>&1 || fail "Xcode not found (full Xcode required, CLT is not enough)"
XV="$(xcodebuild -version 2>/dev/null | head -1 | sed -n 's/^Xcode \([0-9][0-9]*\).*/\1/p')"
[ "${XV:-0}" -ge 15 ] 2>/dev/null || fail "Xcode 15+ required (devicectl era). Found: $(xcodebuild -version 2>/dev/null | head -1)"
command -v python3 >/dev/null 2>&1 || fail "python3 not found"

# --- 1. device: first physical one (8-16 UDID; simulators have UUIDs) ---
UDID="$(xcrun devicectl list devices -j /dev/stdout 2>/dev/null | python3 -c "
import json,sys,re
try:
  d=json.load(sys.stdin)
  for dev in d['result']['devices']:
    p=dev.get('properties',{})
    u=dev.get('udid') or p.get('hardware',{}).get('udid','')
    if re.match(r'^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}\$', u or ''):
      print(u); break
except Exception:
  pass
")"
[ -n "$UDID" ] || fail "No iPhone found. Connect via USB or Wi-Fi, tap Trust, make sure it is unlocked."
info "Device: $UDID"

# --- 2. Team ID: Capabilities -> keychain -> installed-apps heuristic ---
TEAM=""
CAND="$(ls ~/Library/Developer/Xcode/UserData/Capabilities/ 2>/dev/null | sed -n 's/.*-\([A-Z0-9]\{10\}\)-bundle\.json/\1/p' | head -1)"
[ -n "$CAND" ] && TEAM="$CAND"
if [ -z "$TEAM" ]; then
  TEAM="$(for C in $(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*CN=//p'); do
    security find-certificate -c "$C" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU=\([A-Z0-9]\{10\}\).*/\1/p'
  done | head -1)"
fi
if [ -z "$TEAM" ]; then
  TEAM="$(xcrun devicectl device info apps --device "$UDID" -j /dev/stdout 2>/dev/null | python3 -c "
import json,sys,re
try:
  d=json.load(sys.stdin)
  def walk(o):
    if isinstance(o,dict):
      b=o.get('bundleIdentifier','')
      m=re.search(r'\.([A-Z0-9]{10})(\.|$)',b)
      if m: print(m.group(1)); raise StopIteration
      for v in o.values(): walk(v)
    elif isinstance(o,list):
      for v in o: walk(v)
  walk(d)
except StopIteration:
  pass
except Exception:
  pass
")"
fi
if [ -z "$TEAM" ]; then
  echo "Could not detect Team ID automatically."
  echo "Open developer.apple.com/account -> Membership -> Team ID (10 characters)"
  printf "Paste Team ID: "; read -r TEAM
fi
echo "$TEAM" | grep -qE '^[A-Z0-9]{10}$' || fail "Does not look like a Team ID: $TEAM"
info "Team: $TEAM"

# --- 3. unzip IPA, read bundle ids ---
WORK="$SCRIPT_DIR/work"; rm -rf "$WORK"; mkdir -p "$WORK"
unzip -q "$IPA" -d "$WORK" || fail "Failed to unzip IPA"
APP_DIR="$(echo "$WORK"/Payload/*.app)"
[ -d "$APP_DIR" ] || fail "No .app inside Payload"
if [ "$STRIP_WATCH" = 1 ]; then
  for W in "$APP_DIR/Watch" "$APP_DIR/com.apple.WatchPlaceholder"; do
    if [ -e "$W" ]; then rm -rf "$W"; info "Removed Watch app (free accounts cannot sign it): $(basename "$W")"; fi
  done
fi
APP_BID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_DIR/Info.plist" 2>/dev/null)" \
  || fail "No CFBundleIdentifier"
info "App: $APP_BID"

# target app id: reuse the installed one if present, else orig.TEAM
INSTALLED=""; for TRY in 1 2 3; do
  INSTALLED="$(xcrun devicectl device info apps --device "$UDID" -j /dev/stdout 2>/dev/null | python3 -c "
import json,sys
want=sys.argv[1]
try:
  d=json.load(sys.stdin)
  found=[]
  def walk(o):
    if isinstance(o,dict):
      b=o.get('bundleIdentifier','')
      if b==want or b.startswith(want+'.'): found.append(b)
      for v in o.values(): walk(v)
    elif isinstance(o,list):
      for v in o: walk(v)
  walk(d)
  print(found[0] if found else '')
except Exception:
  pass
" "$APP_BID")"; [ -n "$INSTALLED" ] && break; sleep 2; done
if [ -n "$INSTALLED" ]; then APP_NEW="$INSTALLED"; info "Already installed, updating: $APP_NEW (data will be kept)";
else APP_NEW="$APP_BID.$TEAM"; info "New ID: $APP_NEW"; fi

# extensions: app_new + last component of the original
APPEX_LIST=""
for A in "$APP_DIR"/PlugIns/*.appex; do
  [ -d "$A" ] || continue
  OB="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$A/Info.plist" 2>/dev/null)" || continue
  SHORT="${OB##*.}"
  APPEX_LIST="$APPEX_LIST
$(basename "$A" .appex)|$OB|$APP_NEW.$SHORT"
done
if [ -n "$APPEX_LIST" ]; then echo "$APPEX_LIST" | sed 's/^/  appex: /'; fi

# --- 4. stub project to mint profiles ---
STUB="$WORK/stub"; rm -rf "$STUB"; mkdir -p "$STUB"
cp -r "$SCRIPT_DIR/tpl.xcodeproj" "$STUB/StubApp.xcodeproj"
cp -r "$SCRIPT_DIR/tplsrc" "$STUB/StubApp"
PROF="$WORK/profiles"; mkdir -p "$PROF"
mint() { # $1=bundle $2=profile-out
  R="$(xcodebuild -project "$STUB/StubApp.xcodeproj" -target StubApp -configuration Debug \
    -destination "id=$UDID" -allowProvisioningUpdates \
    "DEVELOPMENT_TEAM=$TEAM" "PRODUCT_BUNDLE_IDENTIFIER=$1" \
    "CONFIGURATION_BUILD_DIR=$WORK/build-tmp" build 2>&1)"
  echo "$R" | grep -q "BUILD SUCCEEDED" || {
    echo "$R" | grep -q "no devices" && fail "Apple does not see the device in your team. Open $STUB/StubApp.xcodeproj in Xcode, select your team, destination=iPhone, press Run once, then re-run this script." 3
    echo "$R" | grep -E "error:" | head -5 >&2
    fail "Failed to mint profile for $1"
  }
  cp "$WORK/build-tmp/StubApp.app/embedded.mobileprovision" "$2"
}
info "Minting profiles..."
mint "$APP_NEW" "$PROF/app.mobileprovision" && echo "  ok app"
echo "$APPEX_LIST" | while IFS='|' read -r DIR OB NB; do
  [ -z "$DIR" ] && continue
  mint "$NB" "$PROF/$DIR.mobileprovision" && echo "  ok $DIR"
done

# --- 5. cert matching this team ---
CERT="$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | while IFS= read -r L; do
  N="$(echo "$L" | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p')"
  [ -z "$N" ] && continue
  OU="$(security find-certificate -c "$N" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU=\([A-Z0-9]\{10\}\).*/\1/p')"
  [ "$OU" = "$TEAM" ] && { echo "$N"; break; }
done)"
[ -n "$CERT" ] || fail "No Apple Development certificate for $TEAM (should have been created during profile minting)"
info "Certificate: $CERT"

# --- 6. re-sign: bundle ids + entitlements mirrored from profiles ---
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $APP_NEW" "$APP_DIR/Info.plist"
echo "$APPEX_LIST" | while IFS='|' read -r DIR OB NB; do
  [ -z "$DIR" ] && continue
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $NB" "$APP_DIR/PlugIns/$DIR.appex/Info.plist"
done
TEAM="$TEAM" PROF="$PROF" APPDIR="$APP_DIR" python3 - <<'EOF'
import subprocess, os, plistlib, re
team = os.environ["TEAM"]; profdir = os.environ["PROF"]; appdir = os.environ["APPDIR"]
jobs = [(appdir, "app")]
import glob
for a in sorted(glob.glob(appdir + "/PlugIns/*.appex")):
    jobs.append((a, os.path.basename(a)[:-len(".appex")]))
def cms_plist(path):
    raw = subprocess.run(["security", "cms", "-D", "-i", path], capture_output=True).stdout
    return plistlib.loads(raw)
for binpath, pname in jobs:
    prof = cms_plist(os.path.join(profdir, pname + ".mobileprovision"))
    ent = dict(prof["Entitlements"])
    try:
        raw = subprocess.run(["codesign", "-d", "--entitlements", ":-", binpath],
                             capture_output=True).stdout
        orig = plistlib.loads(raw) if raw.lstrip().startswith(b"<?xml") else {}
    except Exception:
        orig = {}
    if "keychain-access-groups" in orig:
        ent["keychain-access-groups"] = [
            re.sub(r"^[A-Z0-9]{10}\.", team + ".", g) for g in orig["keychain-access-groups"]]
    with open(binpath + ".entitlements.plist", "wb") as f:
        plistlib.dump(ent, f)
    print("  entitlements: " + pname)
EOF
find "$APP_DIR" \( -name "*.framework" -o -name "*.dylib" \) | while IFS= read -r F; do
  codesign -f -s "$CERT" "$F" >/dev/null 2>&1 || true
done
echo "$APPEX_LIST" | while IFS='|' read -r DIR OB NB; do
  [ -z "$DIR" ] && continue
  B="$APP_DIR/PlugIns/$DIR.appex"
  rm -f "$B/embedded.mobileprovision"
  cp "$PROF/$DIR.mobileprovision" "$B/embedded.mobileprovision"
  codesign -f -s "$CERT" --entitlements "$B.entitlements.plist" "$B" || fail "Failed to sign $DIR"
done
rm -f "$APP_DIR/embedded.mobileprovision"
cp "$PROF/app.mobileprovision" "$APP_DIR/embedded.mobileprovision"
codesign -f -s "$CERT" --entitlements "$APP_DIR.entitlements.plist" "$APP_DIR" || fail "Failed to sign the app"

# --- 7. repack, install, launch ---
OUT="$WORK/signed.ipa"; rm -f "$OUT"
(cd "$WORK" && zip -qry "$OUT" Payload) || fail "Failed to repack IPA"
info "Done: $OUT"
xcrun devicectl device install app --device "$UDID" "$OUT" 2>&1 | tail -3
EXP="$(security cms -D -i "$PROF/app.mobileprovision" 2>/dev/null | plutil -extract ExpirationDate raw - 2>/dev/null)"
info "Profile valid until: $EXP — re-run the script after that"
xcrun devicectl device process launch --device "$UDID" "$APP_NEW" 2>&1 | tail -1
info "All done."

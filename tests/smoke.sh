#!/bin/bash
# Offline smoke test for sidex — no device, no network, no Xcode.
# Fake devicectl JSON goes in through SIDEX_DEVICES_JSON / SIDEX_APPS_JSON.
set -u
cd "$(dirname "$0")/.." || exit 1
D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { # $1=desc, $2=cmd, rest=args; stdin passthrough
  local d="$1"; shift
  if "$@"; then ok "$d"; else bad "$d"; fi
}
grepit() { printf '%s\n' "$1" | grep -qF "$2"; }
notgrepit() { ! printf '%s\n' "$1" | grep -qF "$2"; }

# the native helper: sidex compiles it on first use; smoke uses it directly too
HELPER="$(bash -c 'source ./sidex; ensure_helper; printf "%s" "$HELPER"' 2>/dev/null)"
[ -x "$HELPER" ] || { echo "sidex helper build failed"; exit 1; }

cat > "$D/devices.json" <<'EOF'
{"result":{"devices":[
 {"properties":{
   "hardware":{"udid":"00008150-00100D91028A401C","platform":"iOS","reality":"physical","marketingName":"iPhone 17"},
   "software":{"osVersionNumber":{"stringValue":"27.2"}},
   "connection":{"transportType":"wired"},
   "state":{"name":"Maksims iPhone"}}},
 {"properties":{
   "hardware":{"udid":"00008120-000A1B2C3D4E5F60","platform":"iOS","reality":"physical","marketingName":"iPad Pro"},
   "software":{"osVersionNumber":{"stringValue":"26.5"}},
   "connection":{"transportType":"localNetwork"},
   "state":{"name":"iPad"}}},
 {"deviceProperties":{"name":"iPhone 8 old-schema","osVersionNumber":"16.7"},
  "hardwareProperties":{"udid":"00008030-0001122334455667","platform":"iOS","deviceType":"iPhone"},
  "connectionProperties":{"transportType":"wired"}},
 {"properties":{
   "hardware":{"udid":"18B6D734-CF84-4EE2-9F57-C00B6A84C3DE","platform":"iOS","reality":"simulated","marketingName":"iPhone 17"},
   "software":{"osVersionNumber":{"stringValue":"26.5"}},
   "connection":{"transportType":"sameMachine"},
   "state":{"name":"iPhone 17 Sim"}}},
 {"properties":{
   "hardware":{"udid":"00008110-000C0FFEE0BADF00","platform":"tvOS","reality":"physical","marketingName":"Apple TV"},
   "software":{"osVersionNumber":{"stringValue":"26.0"}},
   "connection":{"transportType":"localNetwork"},
   "state":{"name":"Living Room"}}},
  {"deviceProperties":{"name":"iPhone SE 2016","osVersionNumber":"15.8"},
   "hardwareProperties":{"udid":"F1F2F3F4F5F6F7F8F9F0F1F2F3F4F5F6F7F8F9F0","platform":"iOS","deviceType":"iPhone"},
   "connectionProperties":{"transportType":"wired"}}
]}}
EOF

cat > "$D/apps.json" <<'EOF'
{"result":{"apps":[
 {"name":"SideStore","bundleIdentifier":"com.SideStore.SideStore"},
 {"name":"LiveContainer","bundleIdentifier":"com.kdt.livecontainer"},
 {"name":"Some App","bundleIdentifier":"com.example.app.ABCDE12345"},
 {"name":"Some App Widget","bundleIdentifier":"com.example.app.ABCDE12345.Widget"},
 {"name":"Another App","bundleIdentifier":"com.acme.thing.ABCDE12345"},
 {"name":"Third App","bundleIdentifier":"com.acme.other.ABCDE12345"},
 {"name":"Store App","bundleIdentifier":"com.vendor.storeapp"}
]}}
EOF

check "syntax (bash -n)" bash -n sidex

# --- helper cert-hash: the profile's own certificates (issue 2: profile/signing cert must match) ---
/usr/bin/openssl req -x509 -newkey rsa:2048 -keyout "$D/k.pem" -out "$D/c.pem" -days 1 -nodes -subj "/CN=sidex-test" 2>/dev/null
python3 - "$D/fake.mobileprovision" "$D/c.pem" <<'EOF'
import plistlib, sys, base64, hashlib
pem = open(sys.argv[2], "rb").read()
der = base64.b64decode(b"".join(l for l in pem.splitlines() if b"-----" not in l))
open(sys.argv[1], "wb").write(plistlib.dumps({"DeveloperCertificates": [der]}))
print(hashlib.sha1(der).hexdigest().upper())
EOF
GH="$("$HELPER" cert-hash "$D/fake.mobileprovision")"
EXPECT="$(python3 - "$D/fake.mobileprovision" <<'EOF'
import plistlib, sys, hashlib
print(hashlib.sha1(plistlib.load(open(sys.argv[1], "rb"))["DeveloperCertificates"][0]).hexdigest().upper())
EOF
)"
check "cert-hash: sha1 of the profile's own cert bytes" test "$GH" = "$EXPECT"
printf '<?xml version="1.0"?>\n<plist version="1.0"><dict/></plist>' > "$D/empty.mobileprovision"
"$HELPER" cert-hash "$D/empty.mobileprovision" >/dev/null 2>&1
check "cert-hash: missing certs fail loudly" test $? = 1

# --- devices ---
OUT="$(SIDEX_DEVICES_JSON="$D/devices.json" bash sidex devices 2>&1)"
check "devices: physical iPhone listed (new schema)"  grepit "$OUT" "00008150-00100D91028A401C"
check "devices: old schema device still parsed"       grepit "$OUT" "00008030-0001122334455667"
check "devices: old dash-less 40-hex UDID accepted"   grepit "$OUT" "F1F2F3F4F5F6F7F8F9F0F1F2F3F4F5F6F7F8F9F0"
check "devices: USB transport shown"                  grepit "$OUT" "USB"
check "devices: Wi-Fi transport shown"                grepit "$OUT" "Wi-Fi"
check "devices: simulator hidden"                     notgrepit "$OUT" "18B6D734"
check "devices: Apple TV hidden"                      notgrepit "$OUT" "00008110"
check "devices: exactly 4 devices"                    test "$(printf '%s\n' "$OUT" | grep -c '^  ')" = 4

# --- device selection with >1 device ---
SOUT="$(printf '2\n' | SIDEX_DEVICES_JSON="$D/devices.json" bash -c 'source ./sidex; select_device; echo "$UDID"' 2>/dev/null)"
check "select_device: second of three picked" test "$SOUT" = "00008120-000A1B2C3D4E5F60"
cat > "$D/one.json" <<'EOF'
{"result":{"devices":[
 {"properties":{
   "hardware":{"udid":"00008150-00100D91028A401C","platform":"iOS","reality":"physical","marketingName":"iPhone 17"},
   "software":{"osVersionNumber":{"stringValue":"27.2"}},
   "connection":{"transportType":"wired"},
   "state":{"name":"Maksims iPhone"}}}
]}}
EOF
SOUT="$(SIDEX_DEVICES_JSON="$D/one.json" bash -c 'source ./sidex; select_device; echo "$UDID"' 2>/dev/null </dev/null)"
check "select_device: single device auto-picked" test "$SOUT" = "00008150-00100D91028A401C"

# --- apps on device ---
AOUT="$(printf '1\n' | SIDEX_DEVICES_JSON="$D/devices.json" SIDEX_APPS_JSON="$D/apps.json" SIDEX_TEAM=ABCDE12345 bash sidex apps 2>&1)"
check "apps: store app listed"                       grepit "$AOUT" "com.vendor.storeapp"
check "apps: team app marked"                        grepit "$AOUT" "[your team]"
check "apps: team count is 3 (widget dropped)"       grepit "$AOUT" "Signed with your team: 3"

# --- team filter / pair targets via sourcing ---
TOUT="$(SIDEX_APPS_JSON="$D/apps.json" bash -c 'source ./sidex; UDID=FAKE; apps_query team ABCDE12345' 2>/dev/null | wc -l | tr -d ' ')"
check "apps_query team: 3 apps, no widget, no vendor" test "$TOUT" = 3
TOUT="$(SIDEX_APPS_JSON="$D/apps.json" bash -c 'source ./sidex; UDID=FAKE; apps_query pair-targets' 2>/dev/null | cut -f2 | tr '\n' ' ')"
check "pair targets: SideStore first, LiveContainer second" test "$TOUT" = "com.SideStore.SideStore com.kdt.livecontainer "

# --- pick_app: number, name, skip ---
POUT="$(printf '1\n' | SIDEX_APPS_JSON="$D/apps.json" bash -c 'source ./sidex; UDID=FAKE; pick_app' 2>/dev/null)"
check "pick_app: number picks first target" test "$POUT" = "com.SideStore.SideStore"
POUT="$(printf 'liv\n' | SIDEX_APPS_JSON="$D/apps.json" bash -c 'source ./sidex; UDID=FAKE; pick_app' 2>/dev/null)"
check "pick_app: typed name resolves" test "$POUT" = "com.kdt.livecontainer"
printf '\n' | SIDEX_APPS_JSON="$D/apps.json" bash -c 'source ./sidex; UDID=FAKE; pick_app' >/dev/null 2>&1
check "pick_app: Enter skips (rc=1)" test $? = 1
POUT="$(printf '1\n' | SIDEX_APPS_JSON="$D/apps.json" bash -c 'source ./sidex; UDID=FAKE; pick_app' 2>/dev/null)"
check "pick_app: stdout carries only the bundle id" test "$(printf '%s\n' "$POUT" | wc -l | tr -d ' ')" = 1

# --- pair: EPERM from /var/db/lockdown must explain Full Disk Access (usbmuxd out of the loop) ---
mkdir -p "$D/bin"
cat > "$D/bin/sudo" <<'EOF'
#!/bin/bash
echo "cp: /var/db/lockdown/00008150-00100D91028A401C.plist: Operation not permitted" >&2
exit 1
EOF
chmod +x "$D/bin/sudo"
POUT="$(PATH="$D/bin:$PATH" SIDEX_DEVICES_JSON="$D/one.json" SIDEX_USBMUXD_SOCKET="$D/no-usbmuxd.sock" bash sidex pair --save-only </dev/null 2>&1)"
check "pair: EPERM explains Full Disk Access" grepit "$POUT" "Full Disk Access"
check "pair: EPERM says sudo is not enough"   grepit "$POUT" "sudo does NOT bypass it"

# --- pair: usbmuxd ReadPairRecord path (no sudo, no Full Disk Access) ---
SOCK="$D/usbmuxd.sock"
python3 tests/fake_usbmuxd.py "$SOCK" "00008150-00100D91028A401C" "$D/expected.plist" &
SRV=$!
i=0
while [ ! -S "$SOCK" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
POUT="$(SIDEX_DEVICES_JSON="$D/one.json" SIDEX_USBMUXD_SOCKET="$SOCK" bash sidex pair --save-only --out "$D/got.plist" </dev/null 2>&1)"
wait "$SRV"
check "pair: record fetched via usbmuxd, no sudo" cmp -s "$D/got.plist" "$D/expected.plist"
check "pair: usbmuxd path does not fall back"     notgrepit "$POUT" "Falling back"

# --- pair: live pairing from scratch (ProtocolVersion 2 handshake, no stored record) ---
bash tests/cert_check.sh "$HELPER" >"$D/cert.log" 2>&1
check "certificate chain checks (real openssl)" grepit "$(cat "$D/cert.log")" ", 0 failed"

SOCKL="$D/usbmuxd-live.sock"
python3 tests/fake_usbmuxd.py "$SOCKL" "00008150-00100D91028A401C" - --live-pair ok &
SRV=$!
i=0
while [ ! -S "$SOCKL" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
LOUT="$(SIDEX_DEVICES_JSON="$D/one.json" SIDEX_USBMUXD_SOCKET="$SOCKL" bash sidex pair --save-only --out "$D/live.plist" </dev/null 2>&1)"
wait "$SRV"
check "pair live: record created and reported"  grepit "$LOUT" "(paired just now)"
check "pair live: session check ran"            grepit "$LOUT" "Session check passed"
check "pair live: file written, mode 600"       bash -c "[ -s '$D/live.plist' ] && [ \"\$(stat -f %Lp '$D/live.plist')\" = 600 ]"
LKEYS_KEYS="DeviceCertificate EscrowBag HostCertificate HostID HostPrivateKey RootCertificate RootPrivateKey SystemBUID WiFiMACAddress"
keys_ok() {
  local K
  for K in $LKEYS_KEYS; do
    plutil -extract "$K" raw -o - "$D/live.plist" >/dev/null 2>&1 || return 1
  done
}
pem_ok() {
  # certificates are DER in the record (Apple's own format); keys stay PEM
  [ "$(plutil -extract DeviceCertificate raw -o - "$D/live.plist" 2>/dev/null | base64 -D 2>/dev/null | head -c1 | od -An -tu1 | tr -d ' \n')" = "48" ] &&
  [ "$(plutil -extract HostPrivateKey raw -o - "$D/live.plist" 2>/dev/null | base64 -D 2>/dev/null | head -1)" = "-----BEGIN PRIVATE KEY-----" ]
}
vals_ok() {
  [ "$(plutil -extract WiFiMACAddress raw -o - "$D/live.plist" 2>/dev/null)" = "aa:bb:cc:dd:ee:ff" ] &&
  [ "$(plutil -extract SystemBUID raw -o - "$D/live.plist" 2>/dev/null)" = "SIDEX-TEST-BUID" ] &&
  [ "$(plutil -extract EscrowBag raw -o - "$D/live.plist" 2>/dev/null | base64 -D 2>/dev/null | wc -c | tr -d ' ')" = 32 ]
}
check "pair live: full record shape (9 keys)"    keys_ok
check "pair live: certs/keys stored as PEM data" pem_ok
check "pair live: device values stored"          vals_ok

# --- pair: TLS session with the fresh record (SecureTransport client-cert path) ---
SOCKT="$D/usbmuxd-tls.sock"
python3 tests/fake_usbmuxd.py "$SOCKT" "00008150-00100D91028A401C" - --live-pair tls &
SRV=$!
i=0
while [ ! -S "$SOCKT" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
TOUT="$(SIDEX_USBMUXD_SOCKET="$SOCKT" "$HELPER" pair "00008150-00100D91028A401C" "$D/tls.plist" 2>&1)"
wait "$SRV"
check "pair live: TLS session check passes"    grepit "$TOUT" "Session check passed"
check "pair live: TLS check has no soft note"  notgrepit "$TOUT" "could not verify a lockdown session"
check "pair live: pinned cert accepted"        notgrepit "$TOUT" "impersonation"

# a device presenting a certificate from OUTSIDE the record must be rejected (MITM pin)
SOCKP="$D/usbmuxd-tls-bad.sock"
python3 tests/fake_usbmuxd.py "$SOCKP" "00008150-00100D91028A401C" - --live-pair tls-bad &
SRV=$!
i=0
while [ ! -S "$SOCKP" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
PERR="$(SIDEX_USBMUXD_SOCKET="$SOCKP" "$HELPER" pair "00008150-00100D91028A401C" "$D/bad-tls.plist" 2>&1)"
PRC=$?
wait "$SRV"
check "TLS pin: impostor certificate rejected"  grepit "$PERR" "not the one in the pairing record"
check "TLS pin: impostor saves nothing"         bash -c "[ ! -e '$D/bad-tls.plist' ] && [ $PRC -ne 0 ]"

SOCKD="$D/usbmuxd-denied.sock"
python3 tests/fake_usbmuxd.py "$SOCKD" "00008150-00100D91028A401C" - --live-pair denied &
SRV=$!
i=0
while [ ! -S "$SOCKD" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
DOUT="$(SIDEX_USBMUXD_SOCKET="$SOCKD" "$HELPER" pair "00008150-00100D91028A401C" "$D/denied.plist" 2>&1)"
DRC=$?
wait "$SRV"
check "pair live: declined Trust reported"    grepit "$DOUT" "declined"
check "pair live: nothing saved after decline" bash -c "[ ! -e '$D/denied.plist' ] && [ $DRC -ne 0 ]"

SOCKK="$D/usbmuxd-locked.sock"
python3 tests/fake_usbmuxd.py "$SOCKK" "00008150-00100D91028A401C" - --live-pair locked &
SRV=$!
i=0
while [ ! -S "$SOCKK" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
KOUT="$(SIDEX_USBMUXD_SOCKET="$SOCKK" "$HELPER" pair "00008150-00100D91028A401C" "$D/locked.plist" --timeout 0 2>&1)"
KRC=$?
wait "$SRV"
check "pair live: locked iPhone reported"      grepit "$KOUT" "iPhone is locked"
check "pair live: locked run saves nothing"    bash -c "[ ! -e '$D/locked.plist' ] && [ $KRC -ne 0 ]"

# --- menu ---
printf 'q\n' | bash sidex >/dev/null 2>&1
check "menu: q quits with 0" test $? = 0
OUT="$(printf 'q\n' | bash sidex 2>&1)"
check "menu: shows all three actions" bash -c 'printf "%s" "$1" | grep -q "1)" && printf "%s" "$1" | grep -q "2)" && printf "%s" "$1" | grep -q "3)"' _ "$OUT"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

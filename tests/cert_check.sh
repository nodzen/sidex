#!/bin/bash
# Offline checks for the pairing certificate chain (sidex-helper certs).
# Real /usr/bin/openssl, no device. Usage: bash tests/cert_check.sh [HELPER]
set -u
cd "$(dirname "$0")/.." || exit 1
HELPER="${1:-}"
if [ -z "$HELPER" ]; then
  HELPER="$(bash -c 'source ./sidex; ensure_helper; printf "%s" "$HELPER"' 2>/dev/null)"
fi
[ -x "$HELPER" ] || { echo "sidex helper is not built (run sidex once, or pass its path)"; exit 1; }

OSSL=/usr/bin/openssl
D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

"$OSSL" genrsa -out "$D/device.key" 2048 2>/dev/null
"$OSSL" rsa -in "$D/device.key" -pubout -RSAPublicKey_out >"$D/device.pem" 2>/dev/null
"$OSSL" rsa -in "$D/device.key" -pubout -RSAPublicKey_out -outform DER >"$D/device.der" 2>/dev/null

"$HELPER" certs "$D/device.pem" "$D" || { echo "helper certs failed"; exit 1; }

device_verifies()    { "$OSSL" verify -CAfile "$D/root.crt" "$D/device.crt" >/dev/null 2>&1; }
host_verifies()      { "$OSSL" verify -CAfile "$D/root.crt" "$D/host.crt" >/dev/null 2>&1; }
device_key_matches() { "$OSSL" x509 -in "$D/device.crt" -noout -pubkey 2>/dev/null \
                         | "$OSSL" rsa -pubin -pubout -RSAPublicKey_out -outform DER 2>/dev/null | cmp -s - "$D/device.der"; }
host_key_matches()   { "$OSSL" rsa -in "$D/host.pk8" -pubout -RSAPublicKey_out -outform DER >"$D/host.der" 2>/dev/null
                       "$OSSL" x509 -in "$D/host.crt" -noout -pubkey 2>/dev/null \
                         | "$OSSL" rsa -pubin -pubout -RSAPublicKey_out -outform DER 2>/dev/null | cmp -s - "$D/host.der"; }
empty_subject()      { [ -z "$("$OSSL" x509 -in "$D/device.crt" -noout -subject | sed 's/^subject= *//')" ]; }
serial_one()         { "$OSSL" x509 -in "$D/device.crt" -noout -serial | grep -qE "serial=0*1$"; }
sha256_signed()      { "$OSSL" x509 -in "$D/device.crt" -noout -text | grep -q "sha256WithRSAEncryption"; }
leaf_extensions()    { "$OSSL" x509 -in "$D/device.crt" -noout -text | grep -q "CA:FALSE" \
                         && "$OSSL" x509 -in "$D/device.crt" -noout -text | grep -q "Digital Signature, Key Encipherment"; }
root_is_ca()         { "$OSSL" x509 -in "$D/root.crt" -noout -text | grep -q "CA:TRUE"; }
pkcs8_keys()         { head -1 "$D/host.pk8" | grep -q "BEGIN PRIVATE KEY" \
                         && head -1 "$D/root.pk8" | grep -q "BEGIN PRIVATE KEY"; }
spki_input_ok()      { "$OSSL" rsa -in "$D/device.key" -pubout >"$D/spki.pem" 2>/dev/null
                       "$HELPER" certs "$D/spki.pem" "$D/spki-out" >/dev/null 2>&1; }
odd_key_rejected()   { "$OSSL" genrsa -out "$D/odd.key" 3072 2>/dev/null
                       "$OSSL" rsa -in "$D/odd.key" -pubout -RSAPublicKey_out >"$D/odd.pem" 2>/dev/null
                       ! "$HELPER" certs "$D/odd.pem" "$D/odd-out" >/dev/null 2>&1; }

check "device cert verifies against the root"     device_verifies
check "host cert verifies against the root"       host_verifies
check "device cert carries the device public key" device_key_matches
check "host cert carries the host private key"    host_key_matches
check "device cert: empty subject"                empty_subject
check "device cert: serial 1"                     serial_one
check "device cert: SHA-256 signature"            sha256_signed
check "device cert: CA:FALSE + key usage"         leaf_extensions
check "root cert: CA:TRUE"                        root_is_ca
check "private keys stored as PKCS#8 PEM"         pkcs8_keys
check "SPKI public key input accepted"            spki_input_ok
check "non-2048 device key rejected loudly"       odd_key_rejected

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

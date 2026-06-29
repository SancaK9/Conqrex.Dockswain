#!/usr/bin/env bash
# Create a STABLE self-signed code-signing identity for Dockswain (run once).
#
# Why: each `codesign --sign -` (ad-hoc) produces a *different* signature, so macOS
# treats every rebuild as a new app and re-asks permission for the Keychain item
# that holds your SSH passwords — even after you click "Always Allow". Signing with
# a fixed certificate gives the app a stable identity, so "Always Allow" sticks
# across rebuilds.
#
# This identity is local and self-signed; it is NOT an Apple Developer cert and does
# nothing for distribution/notarization. It only stabilizes local signing.
set -e

NAME="Dockswain Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Note: -v lists only *trusted* identities; a self-signed cert is untrusted yet
# still usable by codesign, so we check the full list (no -v).
if security find-identity -p codesigning 2>/dev/null | grep -qF "$NAME"; then
    echo "✓ Identity already exists: $NAME"
    exit 0
fi

echo "Creating self-signed code-signing identity: $NAME"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
prompt             = no
x509_extensions    = v3
[ dn ]
CN = $NAME
[ v3 ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" >/dev/null 2>&1

# -legacy: emit a PKCS12 that Apple's `security` can import (OpenSSL 3's default
# MAC/cipher is rejected by macOS with "MAC verification failed").
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/cert.p12" -passout pass:dockswain -name "$NAME" >/dev/null 2>&1

# Import key+cert; -T lets codesign use the key, -A allows access without a prompt.
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P dockswain \
    -T /usr/bin/codesign -A >/dev/null 2>&1

# Pre-authorize codesign on the private key so the first sign doesn't prompt.
# (May be a no-op on some setups; harmless if it fails.)
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

if security find-identity -p codesigning 2>/dev/null | grep -qF "$NAME"; then
    echo "✓ Created: $NAME"
    echo "  Now run ./build-app.sh — it will sign with this identity."
else
    echo "✗ Could not create the identity. The app will fall back to ad-hoc signing."
    exit 1
fi

#!/usr/bin/env bash
# Print the qBittorrent Web UI password hash for the
# qbittorrent_password_pbkdf2 secret (nasus/secrets.yaml).
# Same format as qBittorrent: PBKDF2-HMAC-SHA512, 100000 iterations,
# 16 byte random salt, 64 byte key, as @ByteArray(salt:key) in base64.
set -euo pipefail

read -rsp "Password: " pw1; echo >&2
read -rsp "Again: " pw2; echo >&2
if [ "$pw1" != "$pw2" ]; then
  echo "The passwords do not match" >&2
  exit 1
fi

# password passed on stdin, so it never shows up in the process list
printf '%s' "$pw1" | python3 -c '
import base64, hashlib, os, sys
pw = sys.stdin.buffer.read()
salt = os.urandom(16)
key = hashlib.pbkdf2_hmac("sha512", pw, salt, 100000, 64)
b64 = lambda b: base64.b64encode(b).decode()
print(f"@ByteArray({b64(salt)}:{b64(key)})")
'

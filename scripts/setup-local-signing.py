#!/usr/bin/env python3
"""Create one persistent beta signing identity. Never installs a trusted root."""
import hashlib
import os
from pathlib import Path
import secrets
import subprocess
import tempfile


def run(*args, **kwargs):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs).stdout


profile = Path.home() / "Library/Application Support/NearClip Signing"
identity_file = profile / "identity.txt"
if identity_file.exists():
    print("A persistent NearClip signing identity is already configured. It was not replaced.")
    raise SystemExit(0)

os.umask(0o077)
keychain = run("/usr/bin/security", "default-keychain", "-d", "user").decode().strip().strip('"')
with tempfile.TemporaryDirectory(prefix="nearclip-signing-") as temp:
    root = Path(temp)
    config = root / "openssl.cnf"
    config.write_text("""[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no
[subject]
CN = NearClip Local Beta Signing
O = NearClip Local Development
[extensions]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
""")
    password = secrets.token_urlsafe(32)
    password_file = root / "password"
    password_file.write_text(password)
    try:
        run("/usr/bin/openssl", "req", "-new", "-x509", "-newkey", "rsa:3072", "-sha256", "-days", "3650",
            "-nodes", "-config", str(config), "-keyout", str(root / "key.pem"), "-out", str(root / "cert.pem"))
        run("/usr/bin/openssl", "pkcs12", "-export", "-inkey", str(root / "key.pem"), "-in", str(root / "cert.pem"),
            "-name", "NearClip Local Beta Signing", "-passout", "file:" + str(password_file), "-out", str(root / "identity.p12"))
        certificate = run("/usr/bin/openssl", "x509", "-in", str(root / "cert.pem"), "-outform", "DER")
        # -x makes the imported private key non-extractable. Only codesign is
        # pre-authorized; there is no -A and no trust-settings modification.
        run("/usr/bin/security", "import", str(root / "identity.p12"), "-k", keychain,
            "-P", password, "-x", "-T", "/usr/bin/codesign")
        profile.mkdir(parents=True, exist_ok=True, mode=0o700)
        (profile / "certificate.cer").write_bytes(certificate)
        identity_file.write_text(hashlib.sha1(certificate).hexdigest().upper() + "\n")
    except subprocess.CalledProcessError as error:
        # Do not print argv: security import contains a temporary P12 password.
        print("Signing setup failed. The temporary key files have been removed.")
        print(error.stderr.decode(errors="replace"))
        raise SystemExit(1)
print("Saved the signing key in the login Keychain and its fingerprint in " + str(identity_file))
print("Keep this Keychain identity for future beta updates. No trusted root was installed.")

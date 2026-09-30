#!/usr/bin/env python3
"""
Generate the NekkoOS login database: PASSWD and SUDOERS.

These two files hold password hashes, so they are gitignored and do not exist
in a fresh clone. build.sh copies them into the FAT16 image (::/ETC/PASSWD
and ::/ETC/SUDOERS); without them the build fails at the mcopy step, and an
image built from an older checkout could ship with no accounts at all.

File formats, as consumed by src/kernel/pas/passwd_parser.pas:

  PASSWD   one account per line
           user:salt-hex:hash-hex:UID:GID:/HOME/user

  SUDOERS  one username per line, no colons, newline separated

HASHING - the one thing that is easy to get wrong:

  The salt is 32 raw bytes, stored in the file as 64 hex characters. The
  hash is computed over the DECODED BYTES, not over the hex text:

      salt_bytes = bytes.fromhex(salt_hex)
      digest     = sha256(salt_bytes + password.encode())

  Hashing the hex string instead yields a different digest and every login
  fails with "ACCESS DENIED" while the file looks perfectly well formed.
  If you are changing this, re-verify against a known-good pair.

The kernel compares the stored hash against its own computation; there is no
second salt source, so the file is the single source of truth.

Usage:
    scripts/gen_auth.py                 # create only what is missing
    scripts/gen_auth.py --force         # regenerate with a fresh random salt
    scripts/gen_auth.py --user root --password secret
    scripts/gen_auth.py --print         # show the account, never the hash

Environment:
    NEKKO_PASSWORD   default password when --password is not given
"""

import argparse
import getpass
import hashlib
import os
import secrets
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PASSWD_PATH = os.path.join(REPO, "passwd")
SUDOERS_PATH = os.path.join(REPO, "sudoers")

SALT_BYTES = 32
DEFAULT_USER = "root"
DEFAULT_UID = 0
DEFAULT_GID = 0
DEFAULT_PASSWORD = "nekko123"


def make_salt():
    """A fresh 32-byte salt, rendered as 64 lowercase hex characters."""
    return secrets.token_bytes(SALT_BYTES).hex()


def hash_password(salt_hex, password):
    """sha256 over the DECODED salt bytes followed by the password."""
    return hashlib.sha256(bytes.fromhex(salt_hex) + password.encode()).hexdigest()


def build_passwd_line(user, password, uid=DEFAULT_UID, gid=DEFAULT_GID):
    salt_hex = make_salt()
    digest = hash_password(salt_hex, password)
    return f"{user}:{salt_hex}:{digest}:{uid}:{gid}:/HOME/{user}\n"


def write_if_missing(path, content, force):
    """Create the file unless it already exists (or --force was given)."""
    if os.path.exists(path) and not force:
        print(f"[gen_auth] kept existing {os.path.basename(path)}")
        return False
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(content)
    # These are credentials; keep them readable only by the owner.
    os.chmod(path, 0o600)
    print(f"[gen_auth] wrote {os.path.basename(path)}")
    return True


def self_test():
    """
    Verify the hashing rule against the known-good pair that was on disk
    before this script existed. A mismatch here means the format drifted.
    """
    salt_hex = "0" * 64
    expected = "14e7b19d62d565cadea0e67c92a49e251f92d1d5e91e5f3681d2720773ac6174"
    actual = hash_password(salt_hex, "nekko123")
    if actual != expected:
        print("[gen_auth] SELF-TEST FAILED: hashing no longer reproduces the "
              "known-good digest", file=sys.stderr)
        print(f"  expected {expected}", file=sys.stderr)
        print(f"  got      {actual}", file=sys.stderr)
        return False
    print("[gen_auth] self-test ok (salt decoded before hashing)")
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--user", default=DEFAULT_USER)
    parser.add_argument("--uid", type=int, default=DEFAULT_UID)
    parser.add_argument("--gid", type=int, default=DEFAULT_GID)
    parser.add_argument("--password", default=None,
                        help="omit to use $NEKKO_PASSWORD, else the default")
    parser.add_argument("--force", action="store_true",
                        help="regenerate even if the file already exists")
    parser.add_argument("--print", dest="show", action="store_true",
                        help="print the resulting account without the hash")
    args = parser.parse_args()

    if not self_test():
        return 1

    password = args.password or os.environ.get("NEKKO_PASSWORD") or DEFAULT_PASSWORD

    line = build_passwd_line(args.user, password, args.uid, args.gid)

    write_if_missing(PASSWD_PATH, line, args.force)
    # A sudoers entry without a matching account would grant nothing, and a
    # sudoers file granting a user who does not exist is a latent privilege
    # bug. Generate both together, and only the user we just created.
    write_if_missing(SUDOERS_PATH, f"{args.user}\n", args.force)

    if args.show:
        salt_hex = line.split(":")[1]
        print(f"user={args.user} uid={args.uid} gid={args.gid} "
              f"salt={salt_hex[:8]}... hash=<{len(salt_hex) and 64} hex chars>")

    return 0


if __name__ == "__main__":
    sys.exit(main())

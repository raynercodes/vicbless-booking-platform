#!/usr/bin/env python3
"""Make Vic's sign-in secrets and print the commands that store them in AWS.

    python backend/scripts/hash_password.py --env dev

It asks for Vic's password (typing is hidden), makes a fresh pepper and session secret, hashes the
password with 600,000 rounds, and prints the `aws ssm put-parameter` commands. Nothing is sent anywhere
and nothing is saved to disk. Run the printed commands yourself, then clear your terminal history.
If you re-run it, run ALL the printed commands again: the three values belong together.
"""

import argparse
import getpass
import secrets
import shlex
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app import security  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--env", choices=["dev", "prod"], required=True)
    parser.add_argument("--region", default="us-east-1")
    args = parser.parse_args()

    password = getpass.getpass("Vic's dashboard password: ")
    if len(password) < 12:
        print("Use at least 12 characters. A few random words works well.", file=sys.stderr)
        return 1
    if getpass.getpass("Type it again: ") != password:
        print("Those did not match.", file=sys.stderr)
        return 1

    pepper = secrets.token_urlsafe(32)
    jwt_secret = secrets.token_urlsafe(48)
    stored = security.hash_password(password, pepper)
    assert security.verify_password(password, stored, pepper)

    print(f"\nRun these {args.env.upper()} commands with your AWS credentials:\n")
    for name, value in (("pepper", pepper), ("jwt-secret", jwt_secret), ("admin-password-hash", stored)):
        print(
            f"aws ssm put-parameter --region {args.region} --name /vicbless/{args.env}/{name} "
            f"--type SecureString --overwrite --value={shlex.quote(value)}"
        )
    print(
        f"""
Also set these (once), with your own values:

aws ssm put-parameter --region {args.region} --name /vicbless/{args.env}/owner-email --type String --overwrite --value='vic@example.com'
aws ssm put-parameter --region {args.region} --name /vicbless/{args.env}/email-from --type String --overwrite --value='Vicbless <onboarding@resend.dev>'
aws ssm put-parameter --region {args.region} --name /vicbless/{args.env}/resend-api-key --type SecureString --overwrite --value='re_...'
"""
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

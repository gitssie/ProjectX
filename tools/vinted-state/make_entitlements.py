#!/usr/bin/env python3
"""Build a one-shot entitlement file from installed Vinted signed entitlements."""
import argparse
import os
import plistlib
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("signed_entitlements", type=Path)
parser.add_argument("output", type=Path)
parser.add_argument("--role", choices=("keychain", "filesystem", "idfv"), required=True)
args = parser.parse_args()
source = plistlib.loads(args.signed_entitlements.read_bytes())
app_id = "4Y2CNF6C99.lt.manodrabuziai.fr"
group = "4Y2CNF6C99.com.vinted.keychain-group"
if source.get("application-identifier") != app_id or source.get("keychain-access-groups") != [group]:
    parser.error("installed target signature differs from the verified app; review scope first")
result = {
    "platform-application": True,
    "com.apple.private.security.no-container": True,
    "com.apple.private.security.container-required": False,
    "com.apple.private.security.no-sandbox": True,
    "com.apple.private.security.storage.AppDataContainers": True,
    "com.apple.private.security.storage.AppBundles": True,
    "com.apple.lsapplicationproxy.deviceidentifierforvendor": True,
}
if args.role == "keychain":
    result["application-identifier"] = app_id
    result["keychain-access-groups"] = [group]
# Refuse overwrite; no password, device address or signing secret is processed.
fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "wb") as out:
    plistlib.dump(result, out)

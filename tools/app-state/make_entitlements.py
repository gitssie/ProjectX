#!/usr/bin/env python3
"""Generate exact worker authority from app-state describe output, not user group guesses."""
import argparse
import os
import plistlib
import re
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("description", type=Path)
parser.add_argument("output", type=Path)
parser.add_argument("--role", required=True, choices=("keychain", "filesystem", "vendor-worker"))
args = parser.parse_args()
description = plistlib.loads(args.description.read_bytes())
ent = description["signedEntitlements"]
bundle = description["bundleID"]
app_id = ent.get("application-identifier", ent.get("com.apple.application-identifier", ""))
team, dot, remainder = app_id.partition(".")
pattern = re.compile(r"[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*\Z")
if not dot or remainder != bundle or not pattern.fullmatch(team) or not pattern.fullmatch(bundle):
    parser.error("signed Team/App identifier mismatch")
declared = ent.get("keychain-access-groups", [])
shared = ent.get("com.apple.security.application-groups", [])
if (not isinstance(declared, list) or not isinstance(shared, list) or
        any(not isinstance(group, str) or not pattern.fullmatch(group) or
            not group.startswith(team + ".") for group in declared) or
        any(not isinstance(group, str) or not pattern.fullmatch(group) or
            not group.startswith("group.") for group in shared)):
    parser.error("unsupported exact group scope; refusing to skip any declared group")
groups = list(dict.fromkeys(declared + [app_id] + shared))
if groups != description["keychainGroups"]:
    parser.error("description scope differs from signed effective groups")
result = {
    "platform-application": True,
    "com.apple.private.security.no-container": True,
    "com.apple.private.security.container-required": False,
    "com.apple.private.security.no-sandbox": True,
}
if args.role != "vendor-worker":
    result.update({
        "com.apple.private.security.storage.AppDataContainers": True,
        "com.apple.private.security.storage.AppBundles": True,
        "com.apple.lsapplicationproxy.deviceidentifierforvendor": True,
    })
if args.role == "keychain":
    result["application-identifier"] = app_id
    if groups:
        result["keychain-access-groups"] = groups
    if shared:
        result["com.apple.security.application-groups"] = list(dict.fromkeys(shared))
fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "wb") as out:
    plistlib.dump(result, out)

#!/usr/bin/env python3
"""Verify private Keychain signing and, when requested, macOS APNs signing."""
import pathlib
import plistlib
import subprocess
import sys

app = pathlib.Path(sys.argv[1])
environment = sys.argv[2] if len(sys.argv) > 2 else None
key = "com.apple.developer.aps-environment"
profile = app / "Contents/embedded.provisionprofile"
if not profile.is_file():
    sys.exit("Secure credential storage requires an embedded macOS provisioning profile.")
signed = subprocess.run(["codesign", "-d", "--entitlements", "-", str(app)], capture_output=True, check=True)
entitlements = plistlib.loads(signed.stdout)
decoded = subprocess.run(["security", "cms", "-D", "-i", str(profile)], capture_output=True, check=True)
profile_entitlements = plistlib.loads(decoded.stdout)["Entitlements"]
if environment is not None and (entitlements.get(key) != environment or profile_entitlements.get(key) != environment):
    sys.exit("The app and provisioning profile must both match the selected APNs environment.")
app_id = "com.apple.application-identifier"
team_id = "com.apple.developer.team-identifier"
for field in (app_id, team_id):
    if not entitlements.get(field) or entitlements[field] != profile_entitlements.get(field):
        sys.exit("The app identity and team must match its macOS provisioning profile.")
with (app / "Contents/Info.plist").open("rb") as source:
    bundle_id = plistlib.load(source)["CFBundleIdentifier"]
if entitlements[app_id] != entitlements[team_id] + "." + bundle_id:
    sys.exit("The signed app must have its own private Keychain application identity.")
details = subprocess.run(["codesign", "-dv", str(app)], capture_output=True, check=True).stderr
if b"Signature=adhoc" in details:
    sys.exit("Ad hoc signatures cannot register with APNs.")
print("Verified private macOS Keychain signing" + (" and APNs (" + environment + ")" if environment else "") + ".")

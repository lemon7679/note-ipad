"""Assembles NoteApp.app from the linked executable, the way xtool's packer does.

usage: make_app.py BINARY APP_DIR INFO_PLIST [--device] [--icon PNG] [--version X.Y.Z]
"""
import argparse
import os
import plistlib
import shutil
import subprocess

ap = argparse.ArgumentParser()
ap.add_argument("binary")
ap.add_argument("app_dir")
ap.add_argument("info_plist")
ap.add_argument("--device", action="store_true", help="iPhoneOS build (default: simulator)")
ap.add_argument("--icon")
ap.add_argument("--version")
args = ap.parse_args()

shutil.rmtree(args.app_dir, ignore_errors=True)
os.makedirs(args.app_dir)
shutil.copy(args.binary, os.path.join(args.app_dir, "NoteApp"))
info = {
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleDevelopmentRegion": "en",
    "CFBundleVersion": "1",
    "CFBundleShortVersionString": "1.0.0",
    "MinimumOSVersion": "17.0",
    "CFBundleIdentifier": "com.lemon7679.note",
    "CFBundleName": "NoteApp",
    "CFBundleExecutable": "NoteApp",
    "CFBundleDisplayName": "NoteApp",
    "CFBundlePackageType": "APPL",
    "CFBundleSupportedPlatforms": ["iPhoneOS" if args.device else "iPhoneSimulator"],
    "LSRequiresIPhoneOS": True,
    "UIDeviceFamily": [1, 2],
    "UISupportedInterfaceOrientations~ipad": [
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationPortraitUpsideDown",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    ],
    "UILaunchScreen": {},
}
with open(args.info_plist, "rb") as f:
    info.update(plistlib.load(f))
if args.version:
    info["CFBundleShortVersionString"] = args.version
if args.icon:
    shutil.copy(args.icon, os.path.join(args.app_dir, os.path.basename(args.icon)))
    info["CFBundleIconFile"] = os.path.splitext(os.path.basename(args.icon))[0]
with open(os.path.join(args.app_dir, "Info.plist"), "wb") as f:
    plistlib.dump(info, f)
# Ad-hoc signature: enough for the simulator; sideloading tools (xtool install,
# Sideloadly, AltStore) re-sign device builds with the user's Apple ID.
subprocess.run(["codesign", "--force", "--sign", "-", args.app_dir], check=True)
print("assembled", args.app_dir)

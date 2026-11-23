"""Assembles NoteApp.app for the iOS Simulator (CI only), like xtool's packer."""
import os
import plistlib
import shutil
import subprocess
import sys

binary, app_dir, info_path = sys.argv[1:4]
shutil.rmtree(app_dir, ignore_errors=True)
os.makedirs(app_dir)
shutil.copy(binary, os.path.join(app_dir, "NoteApp"))
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
    "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
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
with open(info_path, "rb") as f:
    info.update(plistlib.load(f))
with open(os.path.join(app_dir, "Info.plist"), "wb") as f:
    plistlib.dump(info, f)
subprocess.run(["codesign", "--force", "--sign", "-", app_dir], check=True)
print("assembled", app_dir)

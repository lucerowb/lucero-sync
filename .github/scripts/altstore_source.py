#!/usr/bin/env python3
"""Generate an AltStore / SideStore source for a release.

The privacy permissions and bundle id are read from the built app's Info.plist,
because AltStore refuses to install an IPA whose permissions don't match the
source. Usage:

  altstore_source.py <Info.plist> <ipa> <tag> <owner/repo> <out.json>
"""
import datetime
import json
import os
import plistlib
import sys

info_plist, ipa, tag, repo, out = sys.argv[1:6]

with open(info_plist, "rb") as f:
    info = plistlib.load(f)

raw = f"https://raw.githubusercontent.com/{repo}/main/docs/assets"
privacy = {k: v for k, v in sorted(info.items()) if k.startswith("NS") and k.endswith("UsageDescription")}

screens = ["share", "pair", "offer", "backup", "activity"]

source = {
    "name": "Lucero Sync",
    "subtitle": "Private file sharing and photo backup over Wi-Fi",
    "description": "Official source for Lucero Sync, an open-source app for sharing files and backing up photos directly between your own devices on the same Wi-Fi. No cloud, no account.",
    "iconURL": f"{raw}/app-icon.png",
    "website": "https://lucerosync.lucerowb.com",
    "tintColor": "#FFA24A",
    "featuredApps": [info["CFBundleIdentifier"]],
    "apps": [
        {
            "name": "Lucero Sync",
            "bundleIdentifier": info["CFBundleIdentifier"],
            "developerName": "lucerowb",
            "subtitle": "Share files and back up photos between your devices, no cloud.",
            "localizedDescription": (
                "Lucero Sync sends files and text between your iPhone, Android, Mac, Windows and "
                "Linux devices over your Wi-Fi, and backs up your photo library (originals, videos "
                "and Live Photos) to another device. Transfers are encrypted with pinned certificates, "
                "never duplicates a photo, resumes mid-file, and needs no account or server.\n\n"
                "Open source (MIT): https://github.com/" + repo
            ),
            "iconURL": f"{raw}/app-icon.png",
            "tintColor": "#FFA24A",
            "category": "utilities",
            "screenshots": [
                {"imageURL": f"{raw}/screens/{s}.png", "width": 644, "height": 1400} for s in screens
            ],
            "versions": [
                {
                    "version": info["CFBundleShortVersionString"],
                    "buildVersion": str(info["CFBundleVersion"]),
                    "date": datetime.date.today().isoformat(),
                    "localizedDescription": f"See https://github.com/{repo}/releases/tag/{tag}",
                    "downloadURL": f"https://github.com/{repo}/releases/download/{tag}/lucero-sync-unsigned.ipa",
                    "size": os.path.getsize(ipa),
                    "minOSVersion": info.get("MinimumOSVersion", "15.0"),
                }
            ],
            "appPermissions": {"entitlements": ["com.apple.security.application-groups"], "privacy": privacy},
        }
    ],
    "news": [],
}

with open(out, "w") as f:
    json.dump(source, f, indent=2, ensure_ascii=False)
print(f"Wrote {out}: {info['CFBundleIdentifier']} {info['CFBundleShortVersionString']} ({len(privacy)} privacy keys)")

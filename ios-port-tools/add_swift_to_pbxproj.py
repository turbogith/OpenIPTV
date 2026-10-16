#!/usr/bin/env python3
"""Ajoute les 4 fichiers Swift du portage iOS au projet Xcode (ios/Runner.xcodeproj/project.pbxproj).

Usage:
    python3 add_swift_to_pbxproj.py [chemin/vers/project.pbxproj]

- Idempotent : si IosChannels.swift est déjà référencé, ne fait rien.
- Monte IPHONEOS_DEPLOYMENT_TARGET 13.0 -> 15.0 (requis Cast SDK / VPN / AVPlayer moderne).
- GUID fixes (stables) pour des diffs reproductibles.

À lancer après apply_patch.sh (qui copie les .swift), en local comme en CI.
"""
import sys
from pathlib import Path

FILES = [
    ("IosChannels.swift",   "E1A2B3C40000000000000001", "E2A2B3C40000000000000001"),
    ("IosVideoPlayer.swift", "E1A2B3C40000000000000002", "E2A2B3C40000000000000002"),
    ("IosCast.swift",        "E1A2B3C40000000000000003", "E2A2B3C40000000000000003"),
    ("IosVpn.swift",         "E1A2B3C40000000000000004", "E2A2B3C40000000000000004"),
]

BUILD_ANCHOR = "\t\t7884E8682EC3CC0700C636F2 /* SceneDelegate.swift in Sources */ = {isa = PBXBuildFile; fileRef = 7884E8672EC3CC0400C636F2 /* SceneDelegate.swift */; };"
REF_ANCHOR = "\t\t7884E8672EC3CC0400C636F2 /* SceneDelegate.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SceneDelegate.swift; sourceTree = \"<group>\"; };"
SOURCES_ANCHOR = "\t\t\t\t7884E8682EC3CC0700C636F2 /* SceneDelegate.swift in Sources */,"
GROUP_ANCHOR = "\t\t\t\t74858FAD1ED2DC5600515810 /* Runner-Bridging-Header.h */,"


def main() -> int:
    pbx = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("ios/Runner.xcodeproj/project.pbxproj")
    text = pbx.read_text(encoding="utf-8")

    if "IosChannels.swift" in text:
        print("pbxproj déjà patché, rien à faire.")
        return 0

    for anchor in (BUILD_ANCHOR, REF_ANCHOR, SOURCES_ANCHOR, GROUP_ANCHOR):
        if anchor not in text:
            print(f"ERREUR: ancre introuvable dans project.pbxproj:\n{anchor}")
            print("Le projet Xcode a peut-être changé de structure. Ouvre une issue avec ton project.pbxproj.")
            return 1

    build_lines = "\n".join(
        f"\t\t{bf} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fr} /* {name} */; }};"
        for name, fr, bf in FILES
    )
    text = text.replace(BUILD_ANCHOR, BUILD_ANCHOR + "\n" + build_lines, 1)

    ref_lines = "\n".join(
        f"\t\t{fr} /* {name} */ = {{isa = PBXFileReference; fileEncoding = 4; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};"
        for name, fr, _ in FILES
    )
    text = text.replace(REF_ANCHOR, REF_ANCHOR + "\n" + ref_lines, 1)

    sources_lines = "\n".join(
        f"\t\t\t\t{bf} /* {name} in Sources */,"
        for name, _, bf in FILES
    )
    text = text.replace(SOURCES_ANCHOR, SOURCES_ANCHOR + "\n" + sources_lines, 1)

    group_lines = "\n".join(
        f"\t\t\t\t{fr} /* {name} */,"
        for name, fr, _ in FILES
    )
    text = text.replace(GROUP_ANCHOR, GROUP_ANCHOR + "\n" + group_lines, 1)

    text = text.replace("IPHONEOS_DEPLOYMENT_TARGET = 13.0;", "IPHONEOS_DEPLOYMENT_TARGET = 15.0;")

    pbx.write_text(text, encoding="utf-8")
    print(f"OK: {pbx} patché (4 Swift + deployment target 15.0).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

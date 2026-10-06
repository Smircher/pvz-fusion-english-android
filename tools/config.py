"""Shared paths for the build scripts. Every value can be overridden with an env var.

Defaults assume the repo layout used by tools/sync.sh and tools/build_release.sh:
  input/pvzrh*.apk                                   original Chinese APK (bring your own)
  upstream/PVZF-Translation/PvZ_Fusion_Translator/   PC translation (cloned by sync.sh)
  work/                                              intermediate + output files
"""
import glob
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _newest_apk():
    cands = glob.glob(os.path.join(ROOT, "input", "*.apk")) + glob.glob(os.path.join(ROOT, "pvzrh*.apk"))
    return max(cands, key=os.path.getmtime) if cands else os.path.join(ROOT, "input", "pvzrh.apk")


APK = os.environ.get("PVZ_APK") or _newest_apk()          # original Chinese APK
MOD = os.environ.get("PVZ_MOD") or os.path.join(
    ROOT, "upstream", "PVZF-Translation", "PvZ_Fusion_Translator")  # has Dumps/ (CN source)
EN = os.environ.get("PVZ_EN") or os.path.join(MOD, "Localization", "English")
TRANS = os.environ.get("PVZ_TRANS") or os.path.join(ROOT, "translations")  # this repo's extra strings
WORK = os.environ.get("PVZ_WORK") or os.path.join(ROOT, "work")
OUT = os.path.join(WORK, "data.unity3d.v2")                 # patched asset bundle
META_ORIG = os.path.join(WORK, "global-metadata.orig.dat")  # extracted from APK
META_OUT = os.path.join(WORK, "global-metadata.v2.dat")     # patched metadata

os.makedirs(WORK, exist_ok=True)

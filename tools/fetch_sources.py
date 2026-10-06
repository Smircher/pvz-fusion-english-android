"""Locate and download the build inputs for a game version.

1. Reads the upstream PVZF-Translation README's download table and finds the
   "Chinese <ver> | Android" rows (Google Drive / MEGA links to the original APK).
2. Picks a version: --version, or the newest one listed.
3. Resolves the matching translation in the upstream git clone:
     - origin/main, if its CURRENT_GAME_VER targets that version (newest fixes), else
     - the newest release tag for that version (e.g. 3.8.1_beta), checked out as a
       git worktree at upstream/PVZF-Translation@<tag>.
4. Downloads the APK to input/pvzrh<ver>.apk from the listed mirrors in order (MEGA
   built in via pycryptodome, Google Drive via gdown), unless it is already there.

Prints `export NAME=value` lines (PVZ_APK, PVZ_MOD, VERSION, UPSTREAM_REF) for the caller
to eval. Progress goes to stderr.

Usage: python tools/fetch_sources.py [--version 4.0.5.2] [--check] [--list]
  --check  resolve everything but download nothing (APK path may not exist yet)
  --list   print the Android versions in the upstream table and exit
"""
import argparse
import base64
import json
import os
import re
import shlex
import subprocess
import struct
import sys
import urllib.request
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UP = os.path.join(ROOT, "upstream", "PVZF-Translation")
INPUT = os.path.join(ROOT, "input")
ROW = re.compile(r"^\*\*Chinese\s+([\d.]+)\*\*\s*\|\s*Android\s*\|(.*)$", re.M)
LINK = re.compile(r"\[[^\]]*\]\((https?://[^)\s]+)\)")
DRIVE_ID = re.compile(r"drive\.google\.com/file/d/([\w-]+)")
MEGA_FILE = re.compile(r"mega\.nz/file/([\w-]+)#([\w-]+)")


def log(*a):
    print("[fetch]", *a, file=sys.stderr)


def vtuple(s):
    m = re.match(r"\d+(?:\.\d+)*", s)
    return tuple(int(x) for x in m.group(0).split(".")) if m else ()


def matches(target, ver):
    """`ver` (from a tag or CURRENT_GAME_VER, e.g. 4.0.5) targets game version `target`
    (e.g. 4.0.5.2): equal, or a 3+-part prefix of it."""
    t, v = vtuple(target), vtuple(ver)
    return bool(v) and (t == v or (len(v) >= 3 and t[:len(v)] == v))


def git(*args, check=True):
    r = subprocess.run(["git", "-C", UP, *args], capture_output=True, text=True)
    if check and r.returncode:
        sys.exit(f"git {' '.join(args)} failed: {r.stderr.strip()}")
    return r.stdout.strip()


def android_versions():
    readme = os.path.join(UP, "README.md")
    if not os.path.exists(readme):
        sys.exit("upstream clone missing - run: bash tools/sync.sh")
    text = open(readme, encoding="utf-8").read()
    out = {}
    for ver, rest in ROW.findall(text):
        out.setdefault(ver, LINK.findall(rest))
    if not out:
        sys.exit("no 'Chinese <ver> | Android' rows found in upstream README (format changed?)")
    return out


def resolve_translation(version):
    """Return (ref, translator_dir) for the translation matching `version`."""
    cgv = git("show", "origin/main:CURRENT_GAME_VER", check=False).strip()
    if matches(version, cgv):
        git("checkout", "-q", "main")
        git("merge", "-q", "--ff-only", "origin/main")
        return "main@" + git("rev-parse", "--short", "HEAD"), os.path.join(UP, "PvZ_Fusion_Translator")
    log(f"origin/main targets {cgv or '?'}, not {version}; looking for a release tag")
    tags = git("for-each-ref", "--sort=-creatordate", "--format=%(refname:short)", "refs/tags").split()
    cands = [t for t in tags if matches(version, t)]
    cands.sort(key=lambda t: "android" in t)  # prefer the PC translation tags (stable sort keeps newest first)
    if not cands:
        sys.exit(f"no upstream translation matches game version {version} (tags: {' '.join(tags[:8])} ...)")
    tag = cands[0]
    wt = UP + "@" + tag
    if not os.path.isdir(wt):
        log(f"checking out tag {tag} -> {wt}")
        git("worktree", "add", "-q", "--detach", wt, tag)
    return tag, os.path.join(wt, "PvZ_Fusion_Translator")


def valid_apk(path):
    try:
        with zipfile.ZipFile(path) as z:
            z.getinfo("assets/bin/Data/data.unity3d")
            z.getinfo("assets/bin/Data/Managed/Metadata/global-metadata.dat")
        return True
    except (OSError, KeyError, zipfile.BadZipFile):
        return False


def mega_download(handle, key_b64, out):
    """Public MEGA file link -> decrypted file (AES-128-CTR, key/nonce from the link)."""
    from Crypto.Cipher import AES  # pycryptodome, installed into .venv by update_and_build.sh
    key = base64.urlsafe_b64decode(key_b64 + "=" * (-len(key_b64) % 4))
    a = struct.unpack(">8I", key)
    aes_key = struct.pack(">4I", a[0] ^ a[4], a[1] ^ a[5], a[2] ^ a[6], a[3] ^ a[7])
    nonce = struct.pack(">2I", a[4], a[5])
    req = urllib.request.Request("https://g.api.mega.co.nz/cs", method="POST",
                                 data=json.dumps([{"a": "g", "g": 1, "p": handle}]).encode())
    info = json.load(urllib.request.urlopen(req, timeout=60))[0]
    if not isinstance(info, dict) or "g" not in info:
        raise RuntimeError(f"MEGA API error {info}")
    size, done = info["s"], 0
    cipher = AES.new(aes_key, AES.MODE_CTR, nonce=nonce, initial_value=0)
    with urllib.request.urlopen(info["g"], timeout=120) as r, open(out, "wb") as f:
        while chunk := r.read(1 << 20):
            f.write(cipher.decrypt(chunk))
            done += len(chunk)
            print(f"\r[fetch]   {done * 100 // size:3d}% of {size:,} bytes", end="", file=sys.stderr)
    print(file=sys.stderr)
    if done != size:
        raise RuntimeError(f"short download ({done} of {size} bytes)")


def download_apk(links, dest):
    tmp = dest + ".part"
    for url in links:
        m = DRIVE_ID.search(url)
        try:
            if m:
                import gdown  # installed into .venv by update_and_build.sh
                log(f"downloading from Google Drive ({m.group(1)})")
                gdown.download(id=m.group(1), output=tmp, quiet=False)
            elif MEGA_FILE.search(url):
                h, k = MEGA_FILE.search(url).groups()
                log(f"downloading from MEGA ({h})")
                mega_download(h, k, tmp)
            else:
                continue
        except Exception as e:  # try the next mirror
            log(f"  failed: {e}")
            continue
        if os.path.exists(tmp) and valid_apk(tmp):
            os.replace(tmp, dest)
            return
        log("  downloaded file is not a valid game APK, trying next mirror")
    if os.path.exists(tmp):
        os.remove(tmp)
    sys.exit("could not download the APK from any mirror:\n  " + "\n  ".join(links) +
             f"\nDownload it manually to {dest}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()

    vers = android_versions()
    if a.list:
        for v in sorted(vers, key=vtuple, reverse=True):
            print(v)
        return
    version = a.version or max(vers, key=vtuple)
    if version not in vers:
        sys.exit(f"version {version} not in upstream table; available: {', '.join(sorted(vers, key=vtuple))}")
    log(f"game version: {version}")

    ref, mod = resolve_translation(version)
    if not os.path.isdir(os.path.join(mod, "Dumps")):
        sys.exit(f"translation at {mod} has no Dumps/ folder")
    log(f"translation: {ref}")

    apk = os.path.join(INPUT, f"pvzrh{version}.apk")
    if os.path.exists(apk) and valid_apk(apk):
        log(f"APK already present: {apk}")
    elif a.check:
        log(f"APK not downloaded yet (would fetch to {apk})")
    else:
        os.makedirs(INPUT, exist_ok=True)
        download_apk(vers[version], apk)
        log(f"APK saved: {apk} ({os.path.getsize(apk):,} bytes)")

    for k, v in (("PVZ_APK", apk), ("PVZ_MOD", mod), ("VERSION", version), ("UPSTREAM_REF", ref)):
        print(f"export {k}={shlex.quote(v)}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Generates manifest.json for CycleWare from the asset folders of the repository.

Run from the repository root:  python3 make_manifest.py
Folder layout it reads (same names the script uses):
  Cursors/<file>.png            Hitmarkers/<file>.png          HitSounds/<file>.mp3|ogg|wav|flac
  Textures/<Weapon>/<file>.png  WeaponSounds/<Weapon>/<file>.mp3|ogg|wav|flac
  ReloadSounds/<Weapon>/<file>.mp3|ogg|wav|flac
The output is deterministic (sorted, stable revision), so running it again without changes
produces the exact same file and nothing new is committed.
"""
import hashlib
import json
import re
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent

# Extensions the script accepts (images: PNG only; audio: mp3, ogg, wav, flac).
FLAT = {"Cursors": {"png"}, "Hitmarkers": {"png"}, "HitSounds": {"mp3", "ogg", "wav", "flac"}}
AUDIO = {"mp3", "ogg", "wav", "flac"}
PER_WEAPON = {"Textures": {"png"}, "WeaponSounds": AUDIO, "ReloadSounds": AUDIO}
WEAPON_RE = re.compile(r"^[A-Za-z0-9_\-. ]+$")  # same rule as the script (validWeaponName)


def crc32_hex(path: Path) -> str:
    return "%08x" % (zlib.crc32(path.read_bytes()) & 0xFFFFFFFF)  # 8 lowercase hex chars


def entry(path: Path) -> dict:
    return {"path": path.relative_to(ROOT).as_posix(), "crc32": crc32_hex(path)}


def files_in(folder: Path, extensions: set):
    if not folder.is_dir():
        return []
    result = []
    for f in sorted(folder.iterdir(), key=lambda p: p.name.lower()):
        if not f.is_file() or f.name.startswith("."):
            continue
        if f.suffix.lower().lstrip(".") in extensions:
            result.append(f)
        else:
            print(f"  skipped (extension not supported): {f.relative_to(ROOT)}", file=sys.stderr)
    return result


def main() -> int:
    assets = {}
    for category, exts in FLAT.items():
        items = [entry(f) for f in files_in(ROOT / category, exts)]
        if items:
            assets[category] = items

    for category, exts in PER_WEAPON.items():
        base = ROOT / category
        per_weapon = {}
        if base.is_dir():
            for weapon_dir in sorted(base.iterdir(), key=lambda p: p.name.lower()):
                if not weapon_dir.is_dir():
                    continue
                if not WEAPON_RE.match(weapon_dir.name) or weapon_dir.name in (".", ".."):
                    print(f"  skipped (invalid weapon folder name): {weapon_dir.name}", file=sys.stderr)
                    continue
                items = [entry(f) for f in files_in(weapon_dir, exts)]
                if items:
                    per_weapon[weapon_dir.name] = items
        if per_weapon:
            assets[category] = per_weapon

    # The revision only changes when some file or checksum changes.
    digest = hashlib.sha1(json.dumps(assets, sort_keys=True).encode("utf-8")).hexdigest()[:12]
    manifest = {"schemaVersion": 1, "revision": digest, "assets": assets}
    text = json.dumps(manifest, indent=2, sort_keys=True, ensure_ascii=False) + "\n"

    target = ROOT / "manifest.json"
    if target.exists() and target.read_text(encoding="utf-8") == text:
        print("manifest.json is already up to date")
    else:
        target.write_text(text, encoding="utf-8")
        total = sum(len(v) if isinstance(v, list) else sum(len(x) for x in v.values()) for v in assets.values())
        print(f"manifest.json written: {total} assets, revision {digest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Проверка manifest и воспроизводимая упаковка публичных файлов сайта."""

import argparse
import hashlib
import json
import mimetypes
import tarfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2] / "web"
PUBLIC_SUFFIXES = {".html", ".css", ".js", ".svg", ".jpg", ".png", ".webp", ".ico", ".webmanifest"}


def artifacts():
    result = []
    for path in sorted(ROOT.rglob("*")):
        if path.is_symlink():
            raise SystemExit("В web/ запрещены symlink")
        if not path.is_file() or path.suffix not in PUBLIC_SUFFIXES:
            continue
        data = path.read_bytes()
        result.append({
            "file": path.relative_to(ROOT).as_posix(),
            "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "content_type": mimetypes.guess_type(path.name)[0],
        })
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write-manifest", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    expected = {"artifacts": artifacts()}
    manifest = ROOT / "manifest.json"
    if args.write_manifest:
        manifest.write_text(json.dumps(expected, ensure_ascii=False, indent=2) + "\n")
    elif json.loads(manifest.read_text()) != expected:
        raise SystemExit("Manifest не совпадает с публичными файлами")
    if args.output:
        with tarfile.open(args.output, "w", format=tarfile.USTAR_FORMAT) as archive:
            for item in expected["artifacts"]:
                path = ROOT / item["file"]
                info = tarfile.TarInfo(item["file"])
                info.size = item["bytes"]
                info.mode = 0o444
                info.mtime = 0
                with path.open("rb") as source:
                    archive.addfile(info, source)
    print("WEB_PACKAGE_OK files=" + str(len(expected["artifacts"])))


if __name__ == "__main__":
    main()

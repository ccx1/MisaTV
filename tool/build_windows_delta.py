"""Build a Windows file delta from two published ZIP layouts."""

import argparse
import hashlib
import json
import re
import shutil
from dataclasses import dataclass
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

VERSION = re.compile(r"v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.[1-9][0-9]*")
RESERVED = re.compile(r"^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)", re.I)
ANCHORS = ("misatv.exe", "data/app.so", "runtimes/ready.json")


@dataclass
class Entry:
    name: str
    digest: str
    size: int


def index(archive: ZipFile) -> dict[str, Entry]:
    files = {}
    for entry in archive.infolist():
        if entry.is_dir():
            continue
        path = entry.filename.replace("\\", "/")
        parts = path.split("/")
        if any(
            not part or part.endswith((".", " ")) or RESERVED.match(part)
            or re.search(r'[<>:"|?*\x00-\x1f]', part)
            or part.lower() == "userdata"
            for part in parts
        ) or parts[0].lower().startswith(".misatv-update"):
            raise ValueError(f"Unsupported Windows package path: {path}")
        key = path.lower()
        if key in files:
            raise ValueError(f"Duplicate Windows package path: {path}")
        with archive.open(entry) as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        files[key] = Entry(entry.filename, digest, entry.file_size)
    for required in ANCHORS[:2]:
        if required not in files:
            raise ValueError(f"Missing application file: {required}")
    return files


def build(previous: Path, current: Path, output_dir: Path, old: str, new: str) -> Path:
    if (
        not VERSION.fullmatch(old)
        or not VERSION.fullmatch(new)
        or tuple(map(int, old[1:].split("."))) >= tuple(map(int, new[1:].split(".")))
    ):
        raise ValueError("Expected ascending four-part MisaTV release tags")
    with ZipFile(previous) as base, ZipFile(current) as target:
        before, after = index(base), index(target)
        has_runtimes = "runtimes/ready.json" in after
        if has_runtimes != ("runtimes/ready.json" in before):
            raise ValueError("Base and target must have the same Windows package type")
        variant = "full" if has_runtimes else "lite"
        output = output_dir / f"MisaTV-delta-x64-{variant}-{old}-to-{new}.zip"
        files = []
        payload = {}
        for key in sorted(before.keys() | after.keys()):
            original, updated = before.get(key), after.get(key)
            path = (updated or original).name.replace("\\", "/")
            changed = original is None or updated is None or original.digest != updated.digest
            if not changed and key not in ANCHORS:
                continue
            files.append({
                "path": path,
                "before": original.digest if original else None,
                "after": updated.digest if updated else None,
                "size": updated.size if updated else 0,
            })
            if changed and updated:
                payload[path] = updated
        manifest = {"schema": 1, "from": old, "to": new, "variant": variant, "files": files}
        with ZipFile(output, "w", ZIP_DEFLATED, compresslevel=6) as delta:
            delta.writestr("delta.json", json.dumps(manifest, ensure_ascii=False))
            for path, entry in payload.items():
                with target.open(entry.name) as source, delta.open(f"files/{path}", "w") as dest:
                    shutil.copyfileobj(source, dest, 1024 * 1024)
        return output


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, required=True)
    parser.add_argument("--target", type=Path, required=True)
    parser.add_argument("--from", dest="old", required=True)
    parser.add_argument("--to", dest="new", required=True)
    parser.add_argument("--output-dir", type=Path, default=Path("."))
    args = parser.parse_args()
    output = build(args.base, args.target, args.output_dir, args.old, args.new)
    print(f"{output} ({output.stat().st_size} bytes)")


if __name__ == "__main__":
    main()

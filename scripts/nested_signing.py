"""Sign Sparkle's nested executables and bundles from the inside out."""
import pathlib
import subprocess
import sys
import time

MACHO_MAGIC = {bytes.fromhex(value) for value in ["cffaedfe", "cefaedfe", "feedfacf", "feedface", "cafebabe", "bebafeca", "cafebabf", "bfbafeca"]}


def signing_targets(root):
    root = pathlib.Path(root)
    if not root.exists():
        return []
    files, bundles = [], []
    for path in root.rglob("*"):
        if path.is_symlink():
            continue
        if path.is_dir() and path.suffix in {".app", ".xpc", ".framework"}:
            bundles.append(path)
        elif path.is_file() and path.stat().st_mode & 0o111:
            with path.open("rb") as stream:
                if stream.read(4) in MACHO_MAGIC:
                    files.append(path)
    by_depth = lambda path: (-len(path.parts), str(path))
    return sorted(files, key=by_depth) + sorted(bundles, key=by_depth) + [root]


if __name__ == "__main__":
    for target in signing_targets(sys.argv[1]):
        for attempt in range(3):
            result = subprocess.run(["codesign", "--force", "--options", "runtime", "--timestamp",
                "--preserve-metadata=entitlements,identifier", "--keychain", sys.argv[3], "--sign", sys.argv[2], str(target)])
            if result.returncode == 0:
                break
            if attempt == 2:
                sys.exit(result.returncode)
            time.sleep(2)

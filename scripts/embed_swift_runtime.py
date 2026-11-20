"""Embed Xcode's Swift back-deployment libraries before the release bundle is signed."""
import os
from pathlib import Path
import re
import subprocess
import sys


def embed(bundle):
    contents = bundle / "Contents"
    frameworks = contents / "Frameworks"
    frameworks.mkdir(exist_ok=True)
    subprocess.run(["xcrun", "swift-stdlib-tool", "--copy", "--platform", "macosx",
                    "--scan-folder", contents, "--destination", frameworks], check=True)
    # SwiftPM also writes the build machine's Xcode path into the executable's
    # search paths. Bind these imports to the shipped copy even when Xcode is installed.
    for binary in contents.rglob("*"):
        if binary.is_symlink() or not binary.is_file() or not (os.access(binary, os.X_OK) or binary.suffix == ".dylib"):
            continue
        with binary.open("rb") as stream:
            magic = stream.read(4)
        if magic not in (bytes.fromhex("cffaedfe"), bytes.fromhex("cafebabe"), bytes.fromhex("cafebabf")):
            continue
        libraries = subprocess.check_output(["xcrun", "otool", "-L", binary], text=True)
        changes = []
        for name in sorted(set(re.findall(r"^\s+@rpath/(libswift[^/\s]+\.dylib)\s", libraries, re.MULTILINE))):
            library = frameworks / name
            if not library.is_file():
                raise RuntimeError(f"{binary.name} needs {name} but Xcode did not supply it")
            if library != binary:
                changes.extend(["-change", f"@rpath/{name}",
                                "@loader_path/" + os.path.relpath(library, binary.parent)])
        if changes:
            subprocess.run(["xcrun", "install_name_tool", *changes, binary], check=True)


if __name__ == "__main__":
    embed(Path(sys.argv[1]).resolve(strict=True))

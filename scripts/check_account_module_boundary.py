"""Check the shared Swift sources against the Classic baseline and the IPC contract."""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASELINE = "bf156b665308423422dda9837974b9ab629e8c12"
TREES = ("Sources/Typeflux", "Tests/TypefluxTests")
AUTH = Path("Sources/Typeflux/Auth")
KIND = r"(class|struct|enum|actor|protocol|typealias)"
DECLARATION = re.compile(
    r"^(?:(?:@\w+(?:\([^\n)]*\))?|public|private|fileprivate|internal|final|indirect|"
    r"package|nonisolated|open)\s+)*" + KIND + r"\s+([A-Z]\w*)", re.MULTILINE
)
IDENTIFIER = re.compile(r"\b[A-Z]\w*\b")
SHIMS = {
    "TypefluxProduct": {"identifier"},
    "FeatureProcess": {"enabled", "role", "owns", "send"},
    "FeatureAuth": {"refresh"},
    "FeatureRPC": {"Failure.unavailable"},
}


def declarations(source):
    return {match[2] for match in DECLARATION.finditer(source)}


def violations(source, forbidden):
    # Skip comments and literal text, retaining ordinary Swift interpolations.
    source = re.sub(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"', lambda match:
                    " ".join(re.findall(r'\\\((.*?)\)', match[0])) if match[0].startswith('"') else " ",
                    source, flags=re.S)
    result = set(IDENTIFIER.findall(source)) & forbidden
    for name, members in SHIMS.items():
        for match in re.finditer(r'\b' + name + r'\b((?:\s*\.\s*\w+)*)', source):
            chain = re.sub(r'\s+', '', match[1]).lstrip('.')
            if not any(chain == member or chain.startswith(member + '.') for member in members):
                result.add(name + ('.' + chain if chain else ''))
    return sorted(result)


def repository_types(revision=None):
    # Git filters the Swift sources in parallel and includes untracked worktree files.
    options = [] if revision else ["--untracked"]
    refs = [revision] if revision else []
    lines = subprocess.check_output([
        "git", "grep", *options, "-IhE", KIND + r"[[:space:]]+[A-Z]", *refs, "--",
        *(tree + "/*.swift" for tree in TREES),
    ], cwd=ROOT, text=True)
    return declarations(lines)


def product_modules(paths):
    modules = set()
    for path in paths:
        parts = Path(path).parts
        if "Sources" in parts:
            index = parts.index("Sources") + 1
            if index < len(parts):
                modules.add(parts[index])
    return modules


def main():
    manifest = ROOT / "scripts/account_module_files.txt"
    paths = manifest.read_text().splitlines()
    files = {name: (ROOT / name).read_text() for name in paths}
    missing = set((ROOT / AUTH).rglob("*.swift")) - {ROOT / name for name in paths}
    allowed = repository_types(BASELINE) | set(SHIMS)
    for source in files.values():
        allowed.update(declarations(source))
    forbidden = repository_types() - allowed
    baseline_paths = subprocess.check_output(["git", "ls-tree", "-r", "--name-only", BASELINE, "--",
                                              "Sources", "Packages"], cwd=ROOT, text=True).splitlines()
    current_modules = [*ROOT.glob("Sources/*"), *ROOT.glob("Packages/*/Sources/*")]
    forbidden.update({path.name for path in current_modules if path.is_dir()} - product_modules(baseline_paths))
    errors = [f"{path.relative_to(ROOT)}: missing from account manifest" for path in sorted(missing)]
    for name, source in files.items():
        errors.extend(f"{name}: {symbol}" for symbol in violations(source, forbidden))
    for error in errors:
        print(error, file=sys.stderr)
    return bool(errors)


if __name__ == "__main__":
    sys.exit(main())

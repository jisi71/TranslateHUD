#!/usr/bin/env python3
"""Build reviewed function candidates from exact, offline ZIP baselines."""

import argparse
import hashlib
import json
import os
import posixpath
import shutil
import stat
import subprocess
import sys
import zipfile
from contextlib import ExitStack
from pathlib import Path


REPO = Path(__file__).resolve().parent.parent
TESTS = {
    "format": ("bold-prototype/format.test.cjs", "75ba93bcfe4d75074d726e1c2036aa5fb67910bd1bb26703ba3aa7f24a13c057"),
    "email": ("backend/deployment-tests/email-compatibility.js", "c08c30a19d04745397b612b105b8ce5f83f909b03c02e937b521b73559d4e9fa"),
}
COMMON_RESULTS = {
    "src/upstream.js": "eabe9e9012c40ef59837dc8d7455145b72aab7d5d9ba7bd5dbc2acbf54f08e1c",
    "src/structuredBold.js": "4a0a14bc940ae14c1fe6d2fa98372168ff96d7735989c8b36b425fc7324f38ee",
}
BASELINES = {
    "trial": {
        "archive": "2bb77996abe62e71d8690c388592bfecedbb6dece753f162af76c072a382fb11",
        "patch": "e23bd977aa1e2e3d21f54232fa754bc5db1ee8f4bd2c4ad1be265904a624aeca",
        "results": {
            **COMMON_RESULTS,
            "src/trialMessages.js": "d7a627b1efa049321a92baba4892eeeea62c0e38e34ce427345ba1dd09eebf1d",
            "src/trialService.js": "5e8d58415f86b7ae8d5c53dac4e4e2351832c6909116cb83a3a25928b1576157",
        },
    },
    "trial-stream": {
        "archive": "e01e25f377fb40065a9f9e8dd7eca5b93fbcf0143fe53d24b65f1513dc405353",
        "patch": "8626c54364fac6bb03b4b698ac606e7093806823726d4c23e49fa13c0b15796a",
        "results": {
            **COMMON_RESULTS,
            "src/trialMessages.js": "04ab96500511eafd4c38cb58fc73378c4afa37cf4cab6462360f28898f804f44",
            "src/trialService.js": "3befd818da94a337741bd9bfa33a0beb93806cd15116b78ba9f0cb7a6b32311d",
        },
    },
}


def digest(stream):
    hasher = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        hasher.update(chunk)
    return hasher.hexdigest()


def file_digest(path):
    with path.open("rb") as stream:
        return digest(stream)


def archive_manifest(archive):
    entries = {}
    for info in archive.infolist():
        name = info.filename.rstrip("/")
        if (not name or "\\" in name or name.startswith("/") or
                posixpath.normpath(name) != name or name == ".." or name.startswith("../")):
            raise ValueError("unsafe archive path")
        if name in entries:
            raise ValueError(f"duplicate archive entry: {name}")
        mode = info.external_attr >> 16
        if info.create_system != 3:
            raise ValueError(f"unsupported archive permissions: {name}")
        if stat.S_ISDIR(mode) and info.is_dir():
            entry = {"type": "dir", "mode": stat.S_IMODE(mode)}
        elif stat.S_ISREG(mode) and not info.is_dir():
            with archive.open(info) as stream:
                entry = {"type": "file", "mode": stat.S_IMODE(mode), "sha256": digest(stream)}
        elif stat.S_ISLNK(mode) and not info.is_dir():
            target = archive.read(info).decode("utf-8")
            resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name), target))
            if (not target or "\\" in target or target.startswith("/") or
                    resolved == ".." or resolved.startswith("../")):
                raise ValueError(f"unsafe archive symlink: {name}")
            entry = {"type": "link", "mode": stat.S_IMODE(mode), "target": target}
        else:
            raise ValueError(f"unsupported archive entry: {name}")
        entries[name] = entry
    for name in entries:
        parent = posixpath.dirname(name)
        while parent:
            if entries.get(parent, {}).get("type") != "dir":
                raise ValueError(f"missing or unsafe archive parent: {name}")
            parent = posixpath.dirname(parent)
    return entries


def tree_manifest(root):
    entries = {}

    def visit(directory):
        for item in os.scandir(directory):
            path = Path(item.path)
            name = path.relative_to(root).as_posix()
            info = path.lstat()
            mode = stat.S_IMODE(info.st_mode)
            if stat.S_ISDIR(info.st_mode):
                entries[name] = {"type": "dir", "mode": mode}
                visit(path)
            elif stat.S_ISREG(info.st_mode):
                entries[name] = {"type": "file", "mode": mode, "sha256": file_digest(path)}
            elif stat.S_ISLNK(info.st_mode):
                entries[name] = {"type": "link", "mode": mode, "target": os.readlink(path)}
            else:
                raise ValueError(f"unsupported filesystem entry: {name}")

    visit(root)
    return entries


def extract_archive(archive, root, manifest):
    root.mkdir()
    for name, entry in sorted(manifest.items(), key=lambda item: (item[0].count("/"), item[0])):
        path = root / name
        if entry["type"] == "dir":
            path.mkdir()
        elif entry["type"] == "file":
            with archive.open(name) as source, path.open("xb") as dest:
                shutil.copyfileobj(source, dest)
            path.chmod(entry["mode"])
        else:
            mask = os.umask(0)
            try:
                os.symlink(entry["target"], path)
            finally:
                os.umask(mask)
    for name, entry in manifest.items():
        if entry["type"] == "dir":
            (root / name).chmod(entry["mode"])
    if tree_manifest(root) != manifest:
        raise ValueError("extracted tree differs from the verified archive")


def check_changes(before, after, expected):
    changes = {name for name in before.keys() | after.keys() if before.get(name) != after.get(name)}
    if changes != set(expected):
        raise ValueError(f"unexpected changed paths: {sorted(changes ^ set(expected))}")
    for name, expected_hash in expected.items():
        entry = after[name]
        previous = before.get(name)
        if entry != {"type": "file", "mode": 0o644, "sha256": expected_hash}:
            raise ValueError(f"candidate content or mode mismatch: {name}")
        if name == "src/structuredBold.js":
            if previous is not None:
                raise ValueError(f"new file already existed: {name}")
        elif not previous or previous["type"] != "file" or previous["mode"] != entry["mode"]:
            raise ValueError(f"baseline file or mode mismatch: {name}")


def manifest_digest(manifest):
    data = json.dumps(manifest, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()
    return hashlib.sha256(data).hexdigest()


def write_archive(root, manifest, target):
    with zipfile.ZipFile(target, "x", compression=zipfile.ZIP_STORED, allowZip64=True) as archive:
        for name, entry in sorted(manifest.items()):
            kind = entry["type"]
            info = zipfile.ZipInfo(name + ("/" if kind == "dir" else ""), (1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            type_mode = {"dir": stat.S_IFDIR, "file": stat.S_IFREG, "link": stat.S_IFLNK}[kind]
            info.external_attr = ((type_mode | entry["mode"]) << 16) | (0x10 if kind == "dir" else 0)
            if kind == "file":
                with (root / name).open("rb") as source, archive.open(info, "w") as dest:
                    shutil.copyfileobj(source, dest)
            else:
                archive.writestr(info, entry.get("target", ""))
    with zipfile.ZipFile(target) as archive:
        if archive_manifest(archive) != manifest:
            raise ValueError("candidate archive differs from candidate tree")


def run_tests(kind, base, candidate, log_dir):
    env = {"PATH": os.environ.get("PATH", os.defpath), "TZ": "UTC",
           "TRIAL_BASELINE_ROOT": str(base), "TRIAL_CANDIDATE_ROOT": str(candidate)}
    for name, (script, _) in TESTS.items():
        log = log_dir / f"{kind}-{name}.log"
        result = subprocess.run(["node", "--test", str(REPO / script)], cwd=REPO, env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=300)
        log.write_text(result.stdout, encoding="utf-8")
        if result.returncode:
            raise RuntimeError(f"{kind} {name} tests failed; see {log}")
        print(f"{kind}: {name} tests passed")


def build(archives, output):
    if not output.is_absolute() or any(not path.is_absolute() for path in archives.values()):
        raise ValueError("archive and output paths must be absolute")
    parent = output.parent.resolve(strict=True)
    output = parent / output.name
    if output == REPO or REPO in output.parents:
        raise ValueError("output must be outside this repository")
    patches = {kind: REPO / f"bold-prototype/patches/{kind}-bold-and-email.patch" for kind in BASELINES}
    with ExitStack() as stack:
        inputs = {}
        for name, (script, expected_hash) in TESTS.items():
            if file_digest(REPO / script) != expected_hash:
                raise ValueError(f"{name} test SHA-256 mismatch")
        for kind, path in archives.items():
            stream = stack.enter_context(path.open("rb"))
            if digest(stream) != BASELINES[kind]["archive"]:
                raise ValueError(f"{kind} archive SHA-256 mismatch")
            if file_digest(patches[kind]) != BASELINES[kind]["patch"]:
                raise ValueError(f"{kind} patch SHA-256 mismatch")
            stream.seek(0)
            inputs[kind] = stream
        output.mkdir(mode=0o700)
        bases, candidates, logs = (output / name for name in ("baselines", "candidates", "logs"))
        for path in (bases, candidates, logs):
            path.mkdir(mode=0o700)
        report = {"schema": 1, "test_sha256": {name: value[1] for name, value in TESTS.items()}, "functions": {}}
        for kind, stream in inputs.items():
            base, candidate = bases / kind, candidates / kind
            with zipfile.ZipFile(stream) as archive:
                before = archive_manifest(archive)
                extract_archive(archive, base, before)
            stream.seek(0)
            if digest(stream) != BASELINES[kind]["archive"]:
                raise ValueError(f"{kind} archive changed during extraction")
            mask = os.umask(0)
            try:
                shutil.copytree(base, candidate, symlinks=True)
            finally:
                os.umask(mask)
            if tree_manifest(candidate) != before:
                raise ValueError(f"{kind} candidate copy differs from its baseline")
            result = subprocess.run(["patch", "-p1", "-F0", "-f", "-i", str(patches[kind])],
                                    cwd=candidate, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            (logs / f"{kind}-patch.log").write_text(result.stdout, encoding="utf-8")
            if result.returncode:
                raise RuntimeError(f"{kind} patch failed; see {logs / (kind + '-patch.log')}")
            (candidate / "src/structuredBold.js").chmod(0o644)
            after = tree_manifest(candidate)
            check_changes(before, after, BASELINES[kind]["results"])
            run_tests(kind, base, candidate, logs)
            if tree_manifest(base) != before or tree_manifest(candidate) != after:
                raise ValueError(f"{kind} tree changed during tests")
            target = output / f"{kind}-candidate.zip"
            write_archive(candidate, after, target)
            if tree_manifest(candidate) != after:
                raise ValueError(f"{kind} candidate changed during packaging")
            report["functions"][kind] = {
                "baseline_zip_sha256": BASELINES[kind]["archive"],
                "patch_sha256": BASELINES[kind]["patch"],
                "candidate_tree_sha256": manifest_digest(after),
                "candidate_zip_sha256": file_digest(target),
                "changed_files": {name: after[name]["sha256"] for name in sorted(BASELINES[kind]["results"])},
                "tests": {"format": "passed", "email": "passed"},
            }
            print(f"{kind}: candidate ZIP SHA-256 {report['functions'][kind]['candidate_zip_sha256']}")
        (output / "report.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(f"report: {output / 'report.json'}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trial-zip", type=Path, required=True)
    parser.add_argument("--stream-zip", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="new directory outside this repository")
    args = parser.parse_args()
    build({"trial": args.trial_zip, "trial-stream": args.stream_zip}, args.output)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired, zipfile.BadZipFile) as error:
        print(f"build failed: {error}", file=sys.stderr)
        sys.exit(1)

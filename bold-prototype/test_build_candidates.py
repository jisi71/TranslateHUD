import importlib.util
import os
import stat
import tempfile
import unittest
import zipfile
from pathlib import Path


spec = importlib.util.spec_from_file_location("candidate_builder", Path(__file__).with_name("build-candidates.py"))
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


def add(archive, name, mode, data=b""):
    info = zipfile.ZipInfo(name)
    info.create_system = 3
    info.external_attr = mode << 16
    archive.writestr(info, data)


class CandidateBuilderTests(unittest.TestCase):
    def test_archive_round_trip_keeps_executable_and_symlink_and_is_deterministic(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "original.zip"
            with zipfile.ZipFile(source, "w") as archive:
                add(archive, "dir/", stat.S_IFDIR | 0o755)
                add(archive, "dir/tool", stat.S_IFREG | 0o755, b"hello")
                add(archive, "dir/link", stat.S_IFLNK | 0o777, b"tool")
            with zipfile.ZipFile(source) as archive:
                manifest = builder.archive_manifest(archive)
                builder.extract_archive(archive, root / "base", manifest)
            self.assertEqual(builder.tree_manifest(root / "base"), manifest)
            self.assertEqual(os.readlink(root / "base/dir/link"), "tool")
            for name in ("first.zip", "second.zip"):
                builder.write_archive(root / "base", manifest, root / name)
            self.assertEqual(builder.file_digest(root / "first.zip"), builder.file_digest(root / "second.zip"))

    def test_archive_rejects_traversal_and_escaping_symlinks(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for name, mode, data in (
                ("../escape", stat.S_IFREG | 0o644, b"x"),
                ("link", stat.S_IFLNK | 0o777, b"../outside"),
            ):
                archive_path = root / ("bad-link.zip" if name == "link" else "bad-path.zip")
                with zipfile.ZipFile(archive_path, "w") as archive:
                    add(archive, name, mode, data)
                with zipfile.ZipFile(archive_path) as archive, self.assertRaises(ValueError):
                    builder.archive_manifest(archive)

    def test_extra_change_wrong_result_and_wrong_mode_are_rejected(self):
        before = {"src/trialService.js": {"type": "file", "mode": 0o644, "sha256": "old"}}
        after = {
            "src/trialService.js": {"type": "file", "mode": 0o644, "sha256": "new"},
            "src/structuredBold.js": {"type": "file", "mode": 0o644, "sha256": "bold"},
        }
        expected = {"src/trialService.js": "new", "src/structuredBold.js": "bold"}
        builder.check_changes(before, after, expected)
        with self.assertRaises(ValueError):
            builder.check_changes(before, {**after, "extra": {"type": "dir", "mode": 0o755}}, expected)
        with self.assertRaises(ValueError):
            builder.check_changes(before, after, {**expected, "src/trialService.js": "wrong"})
        with self.assertRaises(ValueError):
            builder.check_changes(before, {**after, "src/structuredBold.js": {"type": "file", "mode": 0o755, "sha256": "bold"}}, expected)

    def test_wrong_archive_fails_before_creating_output(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "not-the-baseline.zip"
            source.write_bytes(b"not the verified input")
            before = source.read_bytes()
            output = root / "new-output"
            with self.assertRaisesRegex(ValueError, "archive SHA-256 mismatch"):
                builder.build({"trial": source, "trial-stream": source}, output)
            self.assertFalse(output.exists())
            self.assertEqual(source.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()

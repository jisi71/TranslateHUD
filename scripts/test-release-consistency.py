#!/usr/bin/env python3
"""Exercise the offline release check in copies of the release files."""

from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

from update_appcast import DEFAULT_DOWNLOAD_BASE, SPARKLE_NS


SCRIPTS = Path(__file__).resolve().parent
FILES = (
    "project.yml", "README.md", "appcast.xml", "docs/updates.md",
    "website/index.html", "website/privacy/index.html", "website/js/download.js",
)


class ReleaseConsistencyTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        for name in FILES:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(SCRIPTS.parent / name, path)

    def run_check(self, *args, error=None):
        result = subprocess.run(
            [sys.executable, str(SCRIPTS / "check-release-consistency.py"), "--root", str(self.root), *args],
            text=True, capture_output=True,
        )
        output = result.stdout + result.stderr
        if error is None:
            self.assertEqual(result.returncode, 0, output)
        else:
            self.assertEqual(result.returncode, 1, output)
            self.assertIn(error, result.stderr)

    def replace(self, name, pattern, value):
        path = self.root / name
        new, count = re.subn(pattern, value, path.read_text(encoding="utf-8"), count=1)
        self.assertEqual(count, 1, f"{name} missing {pattern}")
        path.write_text(new, encoding="utf-8")

    def test_current_release(self):
        self.run_check()

    def test_readme_build_drift(self):
        self.replace("README.md", r"（构建号 [0-9]+）", "（构建号 999999）")
        self.run_check(error="README.md 的当前版本和构建号")

    def test_readme_release_notes_drift(self):
        self.replace("README.md", r"docs/releases/v[0-9.]+\.md", "docs/releases/v0.0.0.md")
        self.run_check(error="README.md 的更新说明")

    def test_download_links_on_both_pages(self):
        for name in ("website/index.html", "website/privacy/index.html"):
            with self.subTest(name=name):
                self.replace(name, r"releases/download/v[0-9.]+/", "releases/download/v0.0.0/")
                self.run_check(error=f"{name} 的 DMG 链接")

    def test_homepage_install_label_drift(self):
        self.replace("website/index.html", r"Build [0-9]+ · Notarized", "Build 999999 · Notarized")
        self.run_check(error="中英文安装版本和构建号")

    def test_script_overrides_static_links(self):
        self.replace("website/js/download.js", r"TranslateHUD-[0-9.]+\.dmg", "TranslateHUD-0.0.0.dmg")
        self.run_check(error="website/js/download.js 的 DOWNLOAD_URL")

    def test_script_cache_parameter_drift(self):
        self.replace("website/privacy/index.html", r"download\.js\?v=[0-9.]+", "download.js?v=0.0.0")
        self.run_check(error="website/privacy/index.html 的 download.js 版本参数")

    def test_empty_feed(self):
        (self.root / "appcast.xml").write_text("<rss><channel /></rss>", encoding="utf-8")
        self.run_check(error="appcast.xml 缺少发布条目")

    def test_appcast_build_drift(self):
        path = self.root / "appcast.xml"
        tree = ET.parse(path)
        tree.find(f"./channel/item/{{{SPARKLE_NS}}}version").text = "999999"
        tree.write(path, encoding="utf-8")
        self.run_check(error="appcast.xml 的最新版本和构建号")

    def test_candidate_feed_with_custom_download_base(self):
        base = "https://downloads.example.com/translatehud"
        path = self.root / "candidate.xml"
        tree = ET.parse(self.root / "appcast.xml")
        enclosure = tree.find("./channel/item/enclosure")
        enclosure.set("url", enclosure.get("url").replace(DEFAULT_DOWNLOAD_BASE, base, 1))
        tree.write(path, encoding="utf-8")
        self.run_check("--appcast", str(path), error="candidate.xml 的更新 ZIP")
        self.run_check("--appcast", str(path), "--download-base", base)

    def test_documented_feed_drift(self):
        self.replace("docs/updates.md", r"https://[^\s]+/appcast\.xml", "https://example.com/appcast.xml")
        self.run_check(error="docs/updates.md 的订阅地址")


if __name__ == "__main__":
    unittest.main()

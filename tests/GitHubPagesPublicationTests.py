#!/usr/bin/env python3

import gzip
import hashlib
import importlib.util
import json
import lzma
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = PROJECT_ROOT / "scripts" / "render_github_pages.py"
SPEC = importlib.util.spec_from_file_location("render_github_pages", MODULE_PATH)
assert SPEC and SPEC.loader
renderer = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = renderer
SPEC.loader.exec_module(renderer)


class GitHubPagesPublicationTests(unittest.TestCase):
    def make_repository(self, root: Path) -> tuple[Path, Path]:
        repository = root / "repository"
        pool = repository / "pool"
        pool.mkdir(parents=True)
        package_name = "com.hydra.projectx_9.9.9_iphoneos-arm64e.deb"
        package = pool / package_name
        package.write_bytes(b"fixture-projectx-package\n")

        def package_digest(name: str) -> str:
            return hashlib.new(name, package.read_bytes()).hexdigest()

        packages = "\n".join(
            (
                "Package: com.hydra.projectx",
                "Name: XenSpace",
                "Version: 9.9.9",
                "Architecture: iphoneos-arm64e",
                "Description: Test package",
                "Homepage: https://gitssie.github.io/ProjectX/",
                "Depiction: https://gitssie.github.io/ProjectX/",
                "SileoDepiction: https://gitssie.github.io/ProjectX/depiction.json",
                f"Filename: pool/{package_name}",
                f"Size: {package.stat().st_size}",
                f"MD5sum: {package_digest('md5')}",
                f"SHA1: {package_digest('sha1')}",
                f"SHA256: {package_digest('sha256')}",
                "",
            )
        ).encode()
        (repository / "Packages").write_bytes(packages)
        (repository / "Packages.gz").write_bytes(gzip.compress(packages, mtime=0))
        (repository / "Packages.xz").write_bytes(lzma.compress(packages))
        zstd = subprocess.run(
            ("zstd", "-q", "-19", "-c"),
            input=packages,
            check=True,
            capture_output=True,
        ).stdout
        (repository / "Packages.zst").write_bytes(zstd)

        release_lines = [
            "Origin: XenSpace Local Repository",
            "Label: XenSpace Local Repository",
            "Suite: stable",
            "Codename: projectx-local",
            "Version: 1.0",
            "Architectures: iphoneos-arm64e",
            "Components: main",
            "Description: Local RootHide development packages for XenSpace",
        ]
        algorithms = (("MD5Sum", "md5"), ("SHA1", "sha1"), ("SHA256", "sha256"))
        for section, algorithm in algorithms:
            release_lines.append(section + ":")
            for name in renderer.INDEX_NAMES:
                path = repository / name
                release_lines.append(
                    f" {renderer.digest(path, algorithm)} {path.stat().st_size:16d} {name}"
                )
        (repository / "Release").write_text("\n".join(release_lines) + "\n", encoding="utf-8")
        return repository, package

    def test_renders_complete_public_repository_without_mutating_input(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repository, package = self.make_repository(root)
            original_release = (repository / "Release").read_bytes()
            output = root / "site"

            metadata = renderer.render_site(
                repository, output, "https://gitssie.github.io/ProjectX"
            )

            self.assertEqual(metadata["version"], "9.9.9")
            self.assertEqual(metadata["source_url"], "https://gitssie.github.io/ProjectX/")
            self.assertEqual((repository / "Release").read_bytes(), original_release)
            self.assertEqual((output / "pool" / package.name).read_bytes(), package.read_bytes())
            self.assertTrue((output / ".nojekyll").is_file())
            self.assertTrue((output / "icon.png").is_file())
            self.assertEqual(
                (output / "CydiaIcon.png").read_bytes(),
                (output / "icon.png").read_bytes(),
            )
            self.assertTrue((output / "launch-mark.png").is_file())

            release = (output / "Release").read_text(encoding="utf-8")
            self.assertIn("Origin: XenSpace\n", release)
            self.assertIn("Codename: xenspace\n", release)
            self.assertNotIn("Local Repository", release)

            page = (output / "index.html").read_text(encoding="utf-8")
            self.assertNotRegex(page, r"\{\{[A-Z0-9_]+\}\}")
            self.assertIn("sileo://source/https://gitssie.github.io/ProjectX/", page)
            self.assertIn("prefers-reduced-motion", page)
            self.assertIn("9.9.9", page)

            depiction = json.loads((output / "depiction.json").read_text(encoding="utf-8"))
            self.assertEqual(depiction["class"], "DepictionTabView")
            self.assertEqual(depiction["tabs"][0]["class"], "DepictionStackView")
            self.assertEqual(
                depiction["tabs"][0]["views"][0]["class"], "DepictionMarkdownView"
            )
            self.assertEqual(depiction["tintColor"], "#3167F5")
            self.assertIn("9.9.9", depiction["tabs"][0]["views"][0]["markdown"])
            renderer.validate_repository(output, "https://gitssie.github.io/ProjectX/")
            renderer.validate_depiction(depiction)

    def test_rejects_tampered_package(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repository, package = self.make_repository(root)
            package.write_bytes(package.read_bytes() + b"tampered")
            with self.assertRaisesRegex(renderer.PublicationError, "Size does not match"):
                renderer.render_site(
                    repository, root / "site", "https://gitssie.github.io/ProjectX/"
                )

    def test_rejects_tampered_zstd_index(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repository, _ = self.make_repository(root)
            (repository / "Packages.zst").write_bytes(b"not-a-zstd-stream")
            with self.assertRaisesRegex(renderer.PublicationError, "Packages.zst"):
                renderer.render_site(
                    repository, root / "site", "https://gitssie.github.io/ProjectX/"
                )

    def test_rejects_non_https_and_credentialed_urls(self):
        invalid = (
            "http://example.com/repo/",
            "https://user@example.com/repo/",
            "https://example.com/repo/?token=secret",
        )
        for value in invalid:
            with self.subTest(value=value):
                with self.assertRaises(renderer.PublicationError):
                    renderer.normalize_base_url(value)

    def test_rejects_repository_metadata_for_another_public_url(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repository, _ = self.make_repository(root)
            with self.assertRaisesRegex(renderer.PublicationError, "Homepage"):
                renderer.render_site(repository, root / "site", "https://example.com/repo/")

    def test_rejects_invalid_sileo_depiction_structure(self):
        invalid = {
            "minVersion": "0.4",
            "tabs": [
                {
                    "tabname": "Details",
                    "views": [{"viewClass": "DepictionMarkdownView", "markdown": "Text"}],
                }
            ],
        }
        with self.assertRaisesRegex(renderer.PublicationError, "DepictionTabView"):
            renderer.validate_depiction(invalid)

    def test_rejects_output_that_is_not_empty(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repository, _ = self.make_repository(root)
            output = root / "site"
            output.mkdir()
            (output / "unexpected").write_text("do not overwrite", encoding="utf-8")
            with self.assertRaisesRegex(renderer.PublicationError, "absent or empty"):
                renderer.render_site(repository, output, "https://example.com/repo/")


if __name__ == "__main__":
    unittest.main()

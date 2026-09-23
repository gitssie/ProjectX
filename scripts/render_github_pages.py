#!/usr/bin/env python3
"""Render and validate the public XenSpace Sileo repository site."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import html
import json
import lzma
import re
import shutil
import subprocess
from pathlib import Path, PurePosixPath
from urllib.parse import urlsplit, urlunsplit


PROJECT_ROOT = Path(__file__).resolve().parent.parent
TEMPLATE_ROOT = PROJECT_ROOT / "pages"
INDEX_NAMES = ("Packages", "Packages.gz", "Packages.xz", "Packages.zst")
HASH_FIELDS = {
    "MD5sum": "md5",
    "SHA1": "sha1",
    "SHA256": "sha256",
}


class PublicationError(ValueError):
    pass


def normalize_base_url(value: str) -> str:
    parsed = urlsplit(value)
    if parsed.scheme != "https" or not parsed.netloc:
        raise PublicationError("Pages URL must be an absolute https URL")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise PublicationError("Pages URL must not contain credentials, a query, or a fragment")
    path = parsed.path or "/"
    if not path.endswith("/"):
        path += "/"
    return urlunsplit((parsed.scheme, parsed.netloc, path, "", ""))


def parse_control(text: str) -> dict[str, str]:
    paragraphs = [part for part in re.split(r"\n[ \t]*\n", text.strip()) if part.strip()]
    if len(paragraphs) != 1:
        raise PublicationError("Packages must contain exactly one package stanza")

    fields: dict[str, str] = {}
    current = ""
    for line in paragraphs[0].splitlines():
        if line.startswith((" ", "\t")):
            if not current:
                raise PublicationError("Packages contains an orphan continuation line")
            fields[current] += "\n" + line
            continue
        if ":" not in line:
            raise PublicationError(f"Packages contains an invalid line: {line!r}")
        name, value = line.split(":", 1)
        if not name or name in fields:
            raise PublicationError(f"Packages contains a duplicate or empty field: {name!r}")
        current = name
        fields[name] = value.strip()
    return fields


def digest(path: Path, algorithm: str) -> str:
    hasher = hashlib.new(algorithm)
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(block)
    return hasher.hexdigest()


def require_repository_file(repository: Path, relative_name: str) -> Path:
    candidate = repository / relative_name
    if not candidate.is_file() or candidate.is_symlink():
        raise PublicationError(f"repository file is missing or unsafe: {relative_name}")
    return candidate


def validate_package_path(repository: Path, filename: str) -> Path:
    relative = PurePosixPath(filename)
    if relative.is_absolute() or ".." in relative.parts or len(relative.parts) != 2:
        raise PublicationError("Packages Filename must be one file directly under pool/")
    if relative.parts[0] != "pool" or not relative.name.endswith("_iphoneos-arm64e.deb"):
        raise PublicationError("Packages Filename is not a RootHide package under pool/")
    return require_repository_file(repository, relative.as_posix())


def validate_release(repository: Path) -> None:
    release_path = require_repository_file(repository, "Release")
    lines = release_path.read_text(encoding="utf-8").splitlines()
    for section, algorithm in (("MD5Sum", "md5"), ("SHA1", "sha1"), ("SHA256", "sha256")):
        try:
            start = lines.index(section + ":") + 1
        except ValueError as error:
            raise PublicationError(f"Release is missing {section}") from error
        entries: dict[str, tuple[str, int]] = {}
        for line in lines[start:]:
            if line and not line.startswith((" ", "\t")):
                break
            parts = line.split()
            if len(parts) == 3:
                try:
                    size = int(parts[1])
                except ValueError as error:
                    raise PublicationError(
                        f"Release {section} has an invalid size for {parts[2]}"
                    ) from error
                entries[parts[2]] = (parts[0], size)
        for name in INDEX_NAMES:
            path = require_repository_file(repository, name)
            expected = (digest(path, algorithm), path.stat().st_size)
            if entries.get(name) != expected:
                raise PublicationError(f"Release {section} does not match {name}")


def validate_repository(
    repository: Path, expected_base_url: str | None = None
) -> tuple[dict[str, str], Path]:
    repository = repository.resolve(strict=True)
    packages_path = require_repository_file(repository, "Packages")
    packages = packages_path.read_bytes()
    fields = parse_control(packages.decode("utf-8"))

    required = (
        "Package",
        "Name",
        "Version",
        "Architecture",
        "Filename",
        "Size",
        "MD5sum",
        "SHA1",
        "SHA256",
        "Homepage",
        "Depiction",
        "SileoDepiction",
    )
    missing = [name for name in required if not fields.get(name)]
    if missing:
        raise PublicationError("Packages is missing fields: " + ", ".join(missing))
    if fields["Package"] != "com.hydra.projectx":
        raise PublicationError("Packages contains the wrong package identifier")
    if fields["Architecture"] != "iphoneos-arm64e":
        raise PublicationError("Packages contains the wrong architecture")
    if expected_base_url is not None:
        expected_urls = {
            "Homepage": expected_base_url,
            "Depiction": expected_base_url,
            "SileoDepiction": expected_base_url + "depiction.json",
        }
        for name, expected in expected_urls.items():
            if fields[name] != expected:
                raise PublicationError(f"Packages {name} does not match the public source URL")

    package_path = validate_package_path(repository, fields["Filename"])
    if fields["Size"] != str(package_path.stat().st_size):
        raise PublicationError("Packages Size does not match the deb")
    for field, algorithm in HASH_FIELDS.items():
        if fields[field].lower() != digest(package_path, algorithm):
            raise PublicationError(f"Packages {field} does not match the deb")

    if gzip.decompress(require_repository_file(repository, "Packages.gz").read_bytes()) != packages:
        raise PublicationError("Packages.gz does not expand to Packages")
    if lzma.decompress(require_repository_file(repository, "Packages.xz").read_bytes()) != packages:
        raise PublicationError("Packages.xz does not expand to Packages")
    zstd_path = require_repository_file(repository, "Packages.zst")
    try:
        zstd_result = subprocess.run(
            ("zstd", "-q", "-d", "-c", str(zstd_path)),
            check=False,
            capture_output=True,
        )
    except FileNotFoundError as error:
        raise PublicationError("zstd is required to validate Packages.zst") from error
    if zstd_result.returncode != 0 or zstd_result.stdout != packages:
        raise PublicationError("Packages.zst does not expand to Packages")
    validate_release(repository)
    return fields, package_path


def rewrite_release(release_path: Path) -> None:
    replacements = {
        "Origin": "XenSpace",
        "Label": "XenSpace",
        "Codename": "xenspace",
        "Description": "XenSpace packages for Dopamine RootHide on iOS 15+",
    }
    output: list[str] = []
    seen: set[str] = set()
    for line in release_path.read_text(encoding="utf-8").splitlines():
        name = line.split(":", 1)[0]
        if name in replacements:
            output.append(f"{name}: {replacements[name]}")
            seen.add(name)
        else:
            output.append(line)
    if seen != set(replacements):
        raise PublicationError("Release is missing repository identity fields")
    release_path.write_text("\n".join(output) + "\n", encoding="utf-8")


def format_size(size: int) -> str:
    value = float(size)
    for suffix in ("B", "KB", "MB", "GB"):
        if value < 1024 or suffix == "GB":
            return f"{value:.1f} {suffix}" if suffix != "B" else f"{int(value)} B"
        value /= 1024
    raise AssertionError("unreachable")


def replace_tokens(value: object, replacements: dict[str, str]) -> object:
    if isinstance(value, str):
        for token, replacement in replacements.items():
            value = value.replace(token, replacement)
        return value
    if isinstance(value, list):
        return [replace_tokens(item, replacements) for item in value]
    if isinstance(value, dict):
        return {key: replace_tokens(item, replacements) for key, item in value.items()}
    return value


def validate_depiction(depiction: object) -> None:
    if not isinstance(depiction, dict) or depiction.get("class") != "DepictionTabView":
        raise PublicationError("depiction root must be a DepictionTabView")
    if not isinstance(depiction.get("minVersion"), str):
        raise PublicationError("depiction minVersion must be a string")
    tabs = depiction.get("tabs")
    if not isinstance(tabs, list) or not tabs:
        raise PublicationError("depiction must contain at least one tab")

    required_view_fields = {
        "DepictionMarkdownView": ("markdown",),
        "DepictionSeparatorView": (),
        "DepictionTableButtonView": ("title", "action"),
    }
    for tab in tabs:
        if not isinstance(tab, dict) or tab.get("class") != "DepictionStackView":
            raise PublicationError("each depiction tab must be a DepictionStackView")
        if not isinstance(tab.get("tabname"), str) or not tab["tabname"]:
            raise PublicationError("each depiction tab must have a name")
        views = tab.get("views")
        if not isinstance(views, list) or not views:
            raise PublicationError("each depiction tab must contain views")
        for view in views:
            if not isinstance(view, dict) or view.get("class") not in required_view_fields:
                raise PublicationError("depiction contains an unsupported or unclassified view")
            for name in required_view_fields[view["class"]]:
                if not isinstance(view.get(name), str) or not view[name]:
                    raise PublicationError(
                        f"{view['class']} requires a non-empty {name} string"
                    )
            if "viewClass" in view:
                raise PublicationError("depiction views must use class, not viewClass")

    serialized = json.dumps(depiction, ensure_ascii=False)
    if re.search(r"\{\{[A-Z0-9_]+\}\}", serialized):
        raise PublicationError("depiction template contains unresolved placeholders")


def render_site(repository: Path, output: Path, base_url: str) -> dict[str, str]:
    base_url = normalize_base_url(base_url)
    repository = repository.resolve(strict=True)
    output = output.resolve()
    if output.exists() and any(output.iterdir()):
        raise PublicationError("output directory must be absent or empty")
    output.mkdir(parents=True, exist_ok=True)

    fields, package_path = validate_repository(repository, base_url)
    for name in (*INDEX_NAMES, "Release"):
        shutil.copy2(repository / name, output / name)
    pool = output / "pool"
    pool.mkdir()
    shutil.copy2(package_path, pool / package_path.name)
    rewrite_release(output / "Release")

    # Sileo source URLs omit the terminal slash. Asset links still use the
    # directory base URL above so Packages and depiction paths resolve.
    source_url = base_url.rstrip("/")
    sileo_url = "sileo://source/" + source_url
    package_url = base_url + fields["Filename"]
    raw = {
        "{{SOURCE_URL}}": source_url,
        "{{SILEO_URL}}": sileo_url,
        "{{PACKAGE_URL}}": package_url,
        "{{VERSION}}": fields["Version"],
        "{{ARCHITECTURE}}": fields["Architecture"],
        "{{PACKAGE_SIZE}}": format_size(package_path.stat().st_size),
        "{{SHA256}}": fields["SHA256"],
        "{{PACKAGE_FILENAME}}": package_path.name,
    }
    escaped = {token: html.escape(value, quote=True) for token, value in raw.items()}
    index_template = require_repository_file(TEMPLATE_ROOT, "index.html").read_text(encoding="utf-8")
    for token, value in escaped.items():
        index_template = index_template.replace(token, value)
    if re.search(r"\{\{[A-Z0-9_]+\}\}", index_template):
        raise PublicationError("index template contains unresolved placeholders")
    (output / "index.html").write_text(index_template, encoding="utf-8")

    depiction_template = json.loads(
        require_repository_file(TEMPLATE_ROOT, "depiction.json").read_text(encoding="utf-8")
    )
    depiction = replace_tokens(depiction_template, raw)
    validate_depiction(depiction)
    (output / "depiction.json").write_text(
        json.dumps(depiction, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    shutil.copy2(PROJECT_ROOT / "Icon.png", output / "icon.png")
    shutil.copy2(PROJECT_ROOT / "Icon.png", output / "CydiaIcon.png")
    shutil.copy2(PROJECT_ROOT / "LaunchMark@3x.png", output / "launch-mark.png")
    (output / ".nojekyll").write_text("", encoding="utf-8")

    validate_repository(output, base_url)
    validate_depiction(json.loads((output / "depiction.json").read_text(encoding="utf-8")))
    return {
        "version": fields["Version"],
        "architecture": fields["Architecture"],
        "filename": fields["Filename"],
        "sha256": fields["SHA256"],
        "source_url": source_url,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--base-url", required=True)
    arguments = parser.parse_args()
    try:
        metadata = render_site(arguments.repository, arguments.output, arguments.base_url)
    except (OSError, PublicationError, UnicodeError, json.JSONDecodeError) as error:
        parser.error(str(error))
    for name, value in metadata.items():
        print(f"{name}={value}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

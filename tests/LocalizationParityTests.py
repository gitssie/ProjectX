#!/usr/bin/env python3

import re
import plistlib
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent
STRING_PATTERN = re.compile(r'^\s*"((?:[^"\\]|\\.)+)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$')
FORMAT_SPECIFIER_PATTERN = re.compile(r'%(?:\d+\$)?(?:ll|l|h)?[@dDuUxXfFeEgGcCsSpaA]')
LOCALIZED_CALL_PATTERN = re.compile(r'PXLocalized(?:String|Format)\(@"([^"]+)"')


def load_strings(path: Path) -> dict[str, str]:
    strings: dict[str, str] = {}
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        match = STRING_PATTERN.match(line)
        if not match:
            continue
        key, value = match.groups()
        if key in strings:
            raise AssertionError(f"duplicate key {key!r} in {path}:{line_number}")
        strings[key] = value
    return strings


def main() -> None:
    english = load_strings(PROJECT_ROOT / "en.lproj" / "Localizable.strings")
    simplified_chinese = load_strings(PROJECT_ROOT / "zh-Hans.lproj" / "Localizable.strings")
    assert english.keys() == simplified_chinese.keys(), (
        f"English-only keys: {sorted(english.keys() - simplified_chinese.keys())}; "
        f"zh-Hans-only keys: {sorted(simplified_chinese.keys() - english.keys())}"
    )

    for key in english:
        english_specifiers = FORMAT_SPECIFIER_PATTERN.findall(english[key])
        chinese_specifiers = FORMAT_SPECIFIER_PATTERN.findall(simplified_chinese[key])
        assert english_specifiers == chinese_specifiers, (
            f"format specifier mismatch for {key}: "
            f"{english_specifiers} != {chinese_specifiers}"
        )

    surface_files = (
        "ProjectXViewController.m",
        "PXSettingsHubViewController.m",
        "PXTargetAppsViewController.m",
        "PXSmartLocationViewController.m",
        "CarrierSelectionViewController.m",
    )
    referenced_keys: set[str] = set()
    for file_name in surface_files:
        source = (PROJECT_ROOT / file_name).read_text(encoding="utf-8")
        referenced_keys.update(LOCALIZED_CALL_PATTERN.findall(source))
    missing_keys = referenced_keys - english.keys()
    assert not missing_keys, f"localized UI keys are missing from both resources: {sorted(missing_keys)}"

    localization_wrapper = (PROJECT_ROOT / "PXLocalizedStrings.m").read_text(encoding="utf-8")
    assert "AppleLanguages" not in localization_wrapper

    english_usage_descriptions = load_strings(PROJECT_ROOT / "en.lproj" / "InfoPlist.strings")
    chinese_usage_descriptions = load_strings(PROJECT_ROOT / "zh-Hans.lproj" / "InfoPlist.strings")
    assert english_usage_descriptions.keys() == chinese_usage_descriptions.keys()

    makefile = (PROJECT_ROOT / "Makefile").read_text(encoding="utf-8")
    resource_files_line = next(
        line for line in makefile.splitlines() if line.startswith("ProjectX_RESOURCE_FILES =")
    )
    assert "en.lproj" in resource_files_line
    assert "zh-Hans.lproj" in resource_files_line

    with (PROJECT_ROOT / "Info.plist").open("rb") as info_file:
        application_info = plistlib.load(info_file)
    assert application_info["CFBundleDevelopmentRegion"] == "en"
    assert application_info["CFBundleIdentifier"] == "com.hydra.projectx"
    assert application_info["CFBundleExecutable"] == "ProjectX"
    assert application_info["CFBundleName"] == "XenSpace"
    assert application_info["CFBundleDisplayName"] == "XenSpace"
    assert english["app.title"] == simplified_chinese["app.title"] == "XenSpace"
    assert english["image.settings.about.title"] == "About XenSpace"
    assert simplified_chinese["image.settings.about.title"] == "关于 XenSpace"
    for strings in (
        english,
        simplified_chinese,
        english_usage_descriptions,
        chinese_usage_descriptions,
    ):
        assert all("ProjectX" not in value for value in strings.values())

    control = (PROJECT_ROOT / "control").read_text(encoding="utf-8")
    assert "Package: com.hydra.projectx\n" in control
    assert "Name: XenSpace\n" in control


if __name__ == "__main__":
    main()

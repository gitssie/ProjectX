#!/usr/bin/env python3

from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCE = (PROJECT_ROOT / "ProjectXViewController.m").read_text(encoding="utf-8")


def test_device_information_is_a_single_summary_item() -> None:
    assert "homeSection == PXHomeSectionPhysicalDevice) { return 1; }" in SOURCE
    assert 'case PXHomeSectionPhysicalDevice: return PXLocalizedString(@"image.home.device.title")' in SOURCE
    assert "configurePhysicalDeviceContent:content" in SOURCE


def test_device_information_excludes_unique_identifiers() -> None:
    start = SOURCE.index("- (void)configurePhysicalDeviceContent:")
    end = SOURCE.index("- (void)tableView:", start)
    body = SOURCE[start:end]
    for forbidden in ("identifierForVendor", "advertisingIdentifier", "serialNumber", "UDID"):
        assert forbidden not in body
    assert 'content.text = modelName.length > 0 ? modelName : unknown;' in body
    assert 'NSString *details = [NSString stringWithFormat:@"%@ · %@ · %@"' in body
    assert 'PXLocalizedFormat(@"image.home.device.storage", storageSize)' in body
    assert 'content.secondaryText = details;' in body
    assert 'content.secondaryTextProperties.numberOfLines = 0;' in body
    assert '? record[@"name"] : modelIdentifier' in body
    assert '? record[@"cpuArchitecture"] : unknown' in body
    assert ': @"ARM64"' not in body


if __name__ == "__main__":
    test_device_information_is_a_single_summary_item()
    test_device_information_excludes_unique_identifiers()
    print("Home device information regression tests passed.")

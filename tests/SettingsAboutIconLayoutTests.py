#!/usr/bin/env python3

from pathlib import Path


SOURCE = (Path(__file__).resolve().parents[1] / "PXSettingsHubViewController.m").read_text(
    encoding="utf-8"
)


def test_about_logo_uses_the_same_icon_column_as_other_settings_rows() -> None:
    assert "static const CGFloat PXSettingsAboutLogoSize = 20.0;" in SOURCE
    assert "static const CGFloat PXSettingsIconLayoutSize = 24.0;" in SOURCE
    assert "content.imageProperties.maximumSize = CGSizeMake(PXSettingsAboutLogoSize," in SOURCE
    assert "content.imageProperties.cornerRadius = 4.0;" in SOURCE
    assert "content.imageProperties.reservedLayoutSize = CGSizeMake(PXSettingsIconLayoutSize," in SOURCE


if __name__ == "__main__":
    test_about_logo_uses_the_same_icon_column_as_other_settings_rows()
    print("Settings about icon layout regression tests passed.")

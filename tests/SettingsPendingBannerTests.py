#!/usr/bin/env python3

from pathlib import Path


SOURCE = (Path(__file__).resolve().parents[1] / "PXSettingsHubViewController.m").read_text(
    encoding="utf-8"
)


def test_settings_has_no_persistent_pending_banner() -> None:
    assert "pendingChangesBanner" not in SOURCE
    assert "tableHeaderView" not in SOURCE
    assert "reloadPendingConfigurationSummaries" in SOURCE


if __name__ == "__main__":
    test_settings_has_no_persistent_pending_banner()
    print("Settings pending banner regression tests passed.")

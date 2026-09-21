#!/usr/bin/env python3

from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCE = (PROJECT_ROOT / "ProjectXViewController.m").read_text(encoding="utf-8")


def method_body(start_marker: str, end_marker: str) -> str:
    start = SOURCE.index(start_marker)
    end = SOURCE.index(end_marker, start)
    return SOURCE[start:end]


def test_button_uses_native_loading_state() -> None:
    body = method_body(
        "- (UITableViewCell *)generationCellForTableView:",
        "- (void)configureEnvironmentContent:",
    )
    assert "configuration.showsActivityIndicator = isProcessing;" in body
    assert 'PXLocalizedString(@"image.home.generate.processing_title")' in body
    assert "button.enabled = !isProcessing;" in body


def test_primary_action_has_emphasized_vertical_spacing() -> None:
    body = method_body(
        "- (UITableViewCell *)generationCellForTableView:",
        "- (void)configureEnvironmentContent:",
    )
    assert "PXHomePrimaryActionVerticalInset = 16.0" in SOURCE
    assert "constant:PXHomePrimaryActionVerticalInset" in body
    assert "constant:-PXHomePrimaryActionVerticalInset" in body
    assert "constraintGreaterThanOrEqualToConstant:48.0" in body


def test_success_uses_in_app_notify_instead_of_alert() -> None:
    body = method_body(
        "- (void)handleEnvironmentSucceeded",
        "- (void)handleEnvironmentPartiallyFailedWithMessage:",
    )
    assert "showInAppNotifyWithMessage:" in body
    assert "presentEnvironmentAlertWithTitleKey:" not in body

    notify_body = method_body(
        "- (void)showInAppNotifyWithMessage:",
        "- (void)handleEnvironmentPartiallyFailedWithMessage:",
    )
    assert "UIVisualEffectView" in notify_body
    assert "UNUserNotificationCenter" not in notify_body


if __name__ == "__main__":
    test_button_uses_native_loading_state()
    test_primary_action_has_emphasized_vertical_spacing()
    test_success_uses_in_app_notify_instead_of_alert()
    print("One-tap cleanup feedback regression tests passed.")

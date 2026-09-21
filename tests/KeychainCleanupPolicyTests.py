#!/usr/bin/env python3

from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
CLEANER_SOURCE = (PROJECT_ROOT / "AppDataCleaner.m").read_text(encoding="utf-8")
ONE_SHOT_SOURCE = (PROJECT_ROOT / "PXKeychainOneShot.m").read_text(encoding="utf-8")


def method_body(source: str, start_marker: str, end_marker: str) -> str:
    start = source.index(start_marker)
    end = source.index(end_marker, start)
    return source[start:end]


def test_app_cleanup_requests_exclusive_keychain_groups_only() -> None:
    body = method_body(
        CLEANER_SOURCE,
        "- (void)clearKeychainTargets:",
        "- (void)clearKeychainForBundleID:",
    )
    assert "includeSharedAccessGroups:NO" in body
    assert "includeSharedAccessGroups:YES" not in body


def test_one_shot_reports_protected_shared_groups_without_failing() -> None:
    body = method_body(
        ONE_SHOT_SOURCE,
        "- (PXKeychainOneShotResponse *)executeRequest:",
        "@end\n\n@implementation PXKeychainOneShotEntitlementPlan",
    )
    assert "plan.skippedSharedAccessGroupCount > 0" not in body
    assert "responseByRecordingProtectedSharedAccessGroupCount:" in body


if __name__ == "__main__":
    test_app_cleanup_requests_exclusive_keychain_groups_only()
    test_one_shot_reports_protected_shared_groups_without_failing()
    print("Keychain cleanup policy regression tests passed.")

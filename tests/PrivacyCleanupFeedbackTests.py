#!/usr/bin/env python3

from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCE = (PROJECT_ROOT / "ProjectXViewController.m").read_text(encoding="utf-8")


def method_body(start_marker: str, end_marker: str) -> str:
    start = SOURCE.index(start_marker)
    end = SOURCE.index(end_marker, start)
    return SOURCE[start:end]


def test_cleanup_success_is_non_blocking_and_failure_remains_modal() -> None:
    body = method_body(
        "- (void)presentCleanupResultForName:",
        "- (nullable NSDictionary<NSString *, id> *)resolvedEnvironmentModel",
    )

    success_branch = body.index("if (failures.count == 0) {")
    inline_feedback = body.index("[self setCleanupStatusMessage:", success_branch)
    success_return = body.index("return;", inline_feedback)
    failure_alert = body.index("[self presentEnvironmentAlertWithTitleKey:", success_return)

    assert success_branch < inline_feedback < success_return < failure_alert


if __name__ == "__main__":
    test_cleanup_success_is_non_blocking_and_failure_remains_modal()
    print("Privacy cleanup feedback regression tests passed.")

#!/usr/bin/env python3

from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
CONTROLLER = (PROJECT_ROOT / "PXSmartLocationViewController.m").read_text(encoding="utf-8")
SERVICE = (PROJECT_ROOT / "PXGeoIPLocation.m").read_text(encoding="utf-8")
ZH_STRINGS = (PROJECT_ROOT / "zh-Hans.lproj/Localizable.strings").read_text(encoding="utf-8")
EN_STRINGS = (PROJECT_ROOT / "en.lproj/Localizable.strings").read_text(encoding="utf-8")


def test_ip_labels_omit_public_prefix() -> None:
    assert '"image.location.geo_ip.ipv4.label" = "IPv4";' in ZH_STRINGS
    assert '"image.location.geo_ip.ipv6.label" = "IPv6";' in ZH_STRINGS
    assert '"image.location.geo_ip.ipv4.label" = "IPv4";' in EN_STRINGS
    assert '"image.location.geo_ip.ipv6.label" = "IPv6";' in EN_STRINGS
    for line in ZH_STRINGS.splitlines():
        if line.startswith('"image.location.'):
            assert "公网" not in line


def test_smart_location_uses_geo_ip_without_map_or_device_location() -> None:
    assert "PXGeoIPLocationService" in CONTROLLER
    assert "fetchCurrentGeoIPLocation" in CONTROLLER
    for forbidden in ("MapKit", "MKMapView", "CLLocationManager", "UISearchBar"):
        assert forbidden not in CONTROLLER


def test_geo_ip_request_is_private_and_bounded() -> None:
    assert 'https://ipwho.is/' in SERVICE
    assert "ephemeralSessionConfiguration" in SERVICE
    assert "HTTPShouldSetCookies = NO" in SERVICE
    assert "PXGeoIPMaximumResponseBytes = 256 * 1024" in SERVICE
    assert "didReceiveData:" in SERVICE
    assert "self.responseData.length + data.length > PXGeoIPMaximumResponseBytes" in SERVICE
    assert "timeoutIntervalForRequest = 12.0" in SERVICE
    assert "PXGeoIPAddressIsPublic" in SERVICE


def test_ui_has_loading_retry_and_confirm_states() -> None:
    assert "showsActivityIndicator = self.loading" in CONTROLLER
    assert "self.refreshButton.enabled = !self.loading" in CONTROLLER
    assert "self.currentDetectionSucceeded && !self.loading" in CONTROLLER
    assert "image.location.geo_ip.status.failed" in CONTROLLER
    assert "saveConfiguredLocation" in CONTROLLER
    assert "self.requestRevision != revision" in CONTROLLER
    assert "if (self.view.window)" in CONTROLLER
    assert "image.location.geo_ip.legacy_preserved" in CONTROLLER
    assert "image.location.geo_ip.saved_preserved" in CONTROLLER
    assert "self.savedGeoIPLocation = location" in CONTROLLER
    assert "self.selectedLocationPolicy = [self.displayedLocation" in CONTROLLER
    assert "[self updateCarrierMismatchWarningForLocation:location]" in CONTROLLER
    assert "self.legacyLocationAddress = self.displayedLocation.address" not in CONTROLLER


def test_entering_page_does_not_start_network_detection() -> None:
    view_did_load = CONTROLLER.split("- (void)viewDidLoad {", 1)[1].split("- (void)dealloc", 1)[0]
    refresh_handler = CONTROLLER.split("- (void)handleRefreshTapped:", 1)[1].split(
        "- (void)handleClearLocationTapped:", 1
    )[0]
    assert "[self restoreConfiguredLocation]" in view_did_load
    assert "[self fetchCurrentGeoIPLocation]" not in view_did_load
    assert "[self fetchCurrentGeoIPLocation]" in refresh_handler
    restore_handler = CONTROLLER.split("- (void)restoreConfiguredLocation {", 1)[1].split(
        "- (void)updateCarrierMismatchWarningForLocation:", 1
    )[0]
    assert "self.savedGeoIPLocation = location" in restore_handler
    assert "self.displayedLocation = location" not in restore_handler


def test_saved_ip_addresses_are_rendered_without_detection() -> None:
    render_handler = CONTROLLER.split("- (void)renderLocationState {", 1)[1].split(
        "- (void)fetchCurrentGeoIPLocation {", 1
    )[0]
    assert "self.savedGeoIPLocation.ipv4Address" in render_handler
    assert "self.savedGeoIPLocation.ipv6Address" in render_handler
    use_handler = CONTROLLER.split("- (void)handleUseLocationTapped:", 1)[1].split(
        "- (void)restoreConfiguredLocation {", 1
    )[0]
    assert "policyRepresentationWithIPv4Address:self.detectedIPv4Address" in use_handler
    assert "ipv6Address:self.detectedIPv6Address" in use_handler


def test_location_changes_commit_only_after_confirmation() -> None:
    use_handler = CONTROLLER.split("- (void)handleUseLocationTapped:", 1)[1].split(
        "- (void)handleConfirmTapped:", 1
    )[0]
    clear_handler = CONTROLLER.split("- (void)handleClearLocationTapped:", 1)[1].split(
        "- (void)handleUseLocationTapped:", 1
    )[0]
    confirm_handler = CONTROLLER.split("- (void)handleConfirmTapped:", 1)[1].split(
        "- (void)restoreConfiguredLocation {", 1
    )[0]
    assert "saveConfiguredLocation" not in use_handler
    assert "clearConfiguredLocation" not in clear_handler
    assert "saveConfiguredLocation:self.selectedLocationPolicy" in confirm_handler
    assert "clearConfiguredLocationWithError:&error" in confirm_handler
    assert "[self.navigationController popViewControllerAnimated:YES]" in confirm_handler


def test_manual_detection_requests_both_ip_families_and_uses_matching_geo_fallback() -> None:
    assert 'https://api.ipify.org?format=json' in SERVICE
    assert 'https://api6.ipify.org?format=json' in SERVICE
    assert 'PXGeoIPString(dictionary[@"ip"])' in SERVICE
    assert "fetchPublicIPAddressForFamily:PXGeoIPNetworkFamilyIPv4" in CONTROLLER
    assert "fetchPublicIPAddressForFamily:PXGeoIPNetworkFamilyIPv6" in CONTROLLER
    assert "self.ipv4ValueLabel.text =" in CONTROLLER
    assert "self.ipv6ValueLabel.text =" in CONTROLLER
    assert "self.detectedIPv4Address = error ? nil : address" in CONTROLLER
    assert "self.detectedIPv6Address = error ? nil : address" in CONTROLLER
    assert "self.detectedIPv4Address = [self.pendingLocation\n            publicIPAddressForFamily:PXGeoIPNetworkFamilyIPv4]" in CONTROLLER
    assert "self.detectedIPv6Address = [self.pendingLocation\n            publicIPAddressForFamily:PXGeoIPNetworkFamilyIPv6]" in CONTROLLER
    assert "self.geoRequestCompleted || !self.ipv4RequestCompleted || !self.ipv6RequestCompleted" in CONTROLLER


def test_unified_card_keeps_actions_together_and_clear_is_a_real_button() -> None:
    assert "[cardStack addArrangedSubview:self.actionStack]" in CONTROLLER
    assert "[cardStack addArrangedSubview:clearButton]" in CONTROLLER
    assert 'clearButton.accessibilityIdentifier = @"image-location-clear-saved"' in CONTROLLER
    assert "action:@selector(handleClearLocationTapped:)" in CONTROLLER
    assert "[clearButton.heightAnchor constraintGreaterThanOrEqualToConstant:44.0]" in CONTROLLER
    assert "self.clearSeparator.hidden = !self.hasStoredLocationConfiguration" in CONTROLLER
    assert "self.clearLocationButton.hidden = !self.hasStoredLocationConfiguration" in CONTROLLER
    assert "self.view.bounds.size.width < 390.0 || bodyPointSize > 19.0" in CONTROLLER
    assert "self.legacyLocationAddress = nil;" in CONTROLLER
    assert "self.legacyLocationAddress = nil;\n            self.requestFailed" not in CONTROLLER


if __name__ == "__main__":
    test_ip_labels_omit_public_prefix()
    test_smart_location_uses_geo_ip_without_map_or_device_location()
    test_geo_ip_request_is_private_and_bounded()
    test_ui_has_loading_retry_and_confirm_states()
    test_entering_page_does_not_start_network_detection()
    test_saved_ip_addresses_are_rendered_without_detection()
    test_location_changes_commit_only_after_confirmation()
    test_manual_detection_requests_both_ip_families_and_uses_matching_geo_fallback()
    test_unified_card_keeps_actions_together_and_clear_is_a_real_button()
    print("Smart Location GEO IP regression tests passed.")

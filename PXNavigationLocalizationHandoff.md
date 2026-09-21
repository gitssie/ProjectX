# Image-faithful direct-use UIKit handoff

## Source and design direction

`docs/home.png` is the visual source for this scaffold. The direct-use product keeps the image's compact grouped surfaces, blue semantic action treatment, SF Symbol vocabulary, subtitle-heavy rows, search placement, and selection affordances while respecting iOS Dynamic Type and safe areas. No Profile, account, remote, backup, restore, support, ticket, order, or legacy Security UI is reachable.

## Seven-screen map

| Image screen | Concrete UIKit scaffold | Image regions mapped | Exit and action contract |
|---|---|---|---|
| 1. Home | `ProjectXViewController` | service status, Target Apps summary, current-environment rows, pending banner, primary generation button, direct cleanup rows, physical device, last applied | Root has no Back. Gear pushes Settings. Home **Generate and apply environment** is the only generation/activation action. |
| 2. Settings | `PXSettingsHubViewController` | pending banner, environment model/network/carrier/derived region/location, Target Apps, system language, About | Native Back/edge swipe only. Simple selections persist pending configuration immediately; no Save/Done/Apply control. |
| 3. Target Apps | `PXTargetAppsViewController` | search, User Apps/System Apps groups, real icon/name/Bundle ID rows, checkmarks, count, loading/failure/empty/search-empty states | Native Back only. Each checkmark persists immediately, updates Home/Settings counts, and never generates or activates an environment. |
| 4. Environment Model | `PXEnvironmentModelSelectorViewController` (private in `PXSettingsHubViewController.m`) | search, model catalog rows, current checkmark | Native Back only. Selecting a coherent runtime catalog record persists pending model configuration immediately. |
| 5. Network Type | `PXNetworkTypeSelectorViewController` (private in `PXSettingsHubViewController.m`) | Wi-Fi, 5G NR, 4G LTE, 3G, 2G, No Network radio/checkmark rows | Native Back only. Selection persists pending configuration immediately after capability validation. |
| 6. Carrier | `CarrierSelectionViewController` with `usesPushNavigation=YES` | search, country groups, real carrier names, radio-style single selection, derived-identity explanation | Native Back only. One carrier persists immediately and derives coherent region/language/time-zone/network identity for the next environment. |
| 7. Smart Location | `PXSmartLocationViewController` | address search, map surface/pin, current-location action, address/coordinate card, mismatch warning, clear control, bottom Use This Location | Native Back only. Top Done is intentionally absent. **Use This Location** is the sole location commit action; moving/searching a pin does not commit. |

## Resolved grill-me decisions

1. Target Apps uses immediate persistence, not draft/apply. The image's bottom Apply control is intentionally removed because the user selected immediate toggles. Home remains the only environment-generation action.
2. Smart Location retains only the bottom **Use This Location** action. The image's top Done is intentionally removed to prevent duplicate commits.
3. Carrier is image-faithful immediate single selection. The direct Settings route presents radio-style choice, while legacy modal callers retain their existing isolated contract.
4. Privacy cleanup rows have no chevrons. Each opens the existing localized destructive confirmation alert directly; no cleanup pages are added.
5. Model, network, carrier, Target Apps, and simple settings persist only as pending configuration. They never regenerate or mutate the active environment; Home's primary action is the sole activation seam.

## Coder integration seams

- Populate `PXTargetApp` from eligible installed application records only: exclude ProjectX, daemons, extensions, hidden platform services, and non-injectable entries. Load existing scope with `IdentifierManager.isApplicationInScope:` and persist each toggle via the scoped-app APIs. Roll back and announce localized failure if persistence fails.
- Populate model records from `DeviceModelManager.allDeviceSpecificationRecords`. Persist an entire compatible model/specification record rather than an arbitrary model identifier.
- Restrict network types using the selected model's capability. Do not surface SecurityTab credential, IP, VPN, SSID, or advanced controls.
- Persist exactly one carrier via the carrier-policy seam and derive region, language, time zone, and network identity together. Never offer a contradictory combination.
- Wire Smart Location search/current location/clear/use to `LocationSpoofingManager`; the bottom action alone commits the displayed pin as pending configuration.
- Wire `ProjectXViewController.beginNewEnvironment` to the existing automatic coordinator. Only this call activates a newly generated environment.
- Wire existing bounded cleanup implementations behind the direct Home confirmation actions. Do not widen deletion scope.

## Localization and accessibility

- `PXLocalizedString` / `PXLocalizedFormat` resolve the paired `en.lproj` and `zh-Hans.lproj` resources through the system bundle. There is no in-app language override.
- Localize every title, subtitle, action, alert, state, accessibility label, hint, selection value, and announcement. Keep product/technical names, model/catalog data, Bundle IDs, coordinates, paths, logs, payloads, and server-authored text unmodified.
- Interactive rows and controls provide 44-point or larger targets; compact-height screens scroll the table content and keep the map's bottom commit action safe-area pinned. Native navigation owns Back and edge swipe.
- The scaffold uses Dynamic Type text styles, semantic system colors, SF Symbols, system grouped backgrounds, standard selection traits, and explicit VoiceOver state/value/hints. Verify English and Chinese at the largest accessibility text size and in Dark Mode.

## Device validation checklist

1. Compare each row, grouping, warning, count, primary action, and selection state against `docs/home.png`; the five intentional interaction deviations above are approved.
2. Exercise Home → each of six pushed destinations → native Back and edge swipe; verify no duplicate Back/Done/Apply affordances.
3. Verify immediate toggles update Home/Settings summaries but do not trigger generation, cleanup, or active-environment mutation.
4. Verify Smart Location only commits with the bottom action; test current-location, search, clear, derived-region mismatch, and no-location states.
5. Verify Target Apps loading, permission/enumeration failure, no eligible apps, empty search, user/system groups, icons, long Bundle IDs, one/many selected counts, and persistence rollback.
6. Verify all confirmations are localized, bounded, and only destructive after explicit confirmation.

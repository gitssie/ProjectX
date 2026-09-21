# ProjectX reference-parity audit

**Scope.** This is a source-grounded audit of the seven images in
`docs/references/`. The reference is evidence of a possible workflow, not a
specification to copy verbatim. In particular, ProjectX remains an iPhone-only,
RootHide-only, local UIKit tool. It must generate one coherent environment,
must not launch target apps, must preserve explicit target-app ownership during
cleanup, and must not add profile management, backup/restore, remote APIs, or
account/authorization flows.

**Method.** The inventory/matrix below is canonical: each reference-visible
control has one identifier and one row. A row that names a visible, repeated
list of options enumerates the labels visible in the photograph as one
homogeneous control class; all instances have the same current behavior and
gap. `Status` is functional parity only, not a statement that the screens look
alike.

## Status legend

| Status | Meaning in this audit |
| --- | --- |
| `complete` | A current, user-reachable ProjectX path wires the equivalent operation through to its safety boundary. |
| `partial` | A current path works, but its interaction, scope, output, or required data flow differs materially. |
| `UI-only` | A user-facing control exists but has no verified effect. No row currently meets this status. |
| `backend-only` | A usable implementation seam exists, but no current UIKit path exposes the reference behavior. |
| `placeholder/dead` | A visible-looking or persisted concept has an explicit unimplemented/dead activation path. |
| `missing` | No matching source seam was found. This does not authorize a new control. |
| `intentionally different` | ProjectX deliberately declines the reference behavior to preserve a product invariant. |
| `unsafe/unknown` | A related legacy seam exists or the reference implication is high risk, but real behavior has not been established. Do not expose it as a working switch. |

## Source and test anchors

The table uses these exact seams. Paths are relative to `ProjectX/`.

| Area | Current source evidence | Existing validation seam |
| --- | --- | --- |
| Home, status, generation, individual cleanup | `ProjectXViewController` (`ProjectXViewController.m`), especially `refreshEnvironmentSummary`, `beginNewEnvironment`, and `beginCleanupAction:name:` | `PXAutomaticEnvironmentCoordinatorTests.m:testSuccessfulRunUsesOneOrderedAutomaticEnvironmentFlow`, `testActivationFailureNeverReportsSuccessOrRelaunchesTargets` |
| Pending configuration | `PXEnvironmentPolicyStore` (`PXEnvironmentPolicy.m`), especially `writePolicy:`, `saveSelectedModelRecord:physicalModelRecord:hostGraphicsCapabilities:error:`, `saveSelectedNetworkType:modelRecord:error:` | Policy generation behavior is covered alongside manifest tests in `ProfileManifestTests.m`. |
| Coherent environment generation | `PXProfileGenerator.generateManifestWithInput:error:` (`ProfileManifest.m`) | `ProfileManifestTests.m:testPendingNetworkTypeControlsGeneratedTransportAndRadio`, `testUnsupportedPending5GModelFailsClosed`, `testIncompatibleIPhoneFourteenProIsRejectedBeforeProfileGeneration` |
| Model selection | `PXSettingsHubViewController.handleModelTapped`, `compatibilityPresentationByIdentifierForModelRecords:physicalModelRecord:`, and `PXEnvironmentModelSelectorViewController` (`PXSettingsHubViewController.m`) | `DeviceModelManagerTests.m:testProductionCatalogContainsOnlyIPhoneRecords`, `testEveryCatalogRecordHasStructuredCompatibilityClassification` |
| Carrier selection | `PXSettingsHubViewController.handleCarrierTapped` and `carrierSelectionViewController:persistSelectedCarrierIDs:`; `CarrierSelectionViewController.tableView:didSelectRowAtIndexPath:` | `TrustedCarrierPolicyTests.m:testExplicitPolicySaveRejectsEmptyAndPersistsOneStableCarrierID`, `testLegacyMultipleAndInvalidCarrierIDsMigrateDeterministicallyToOne` |
| Target-app discovery and selection | `PXTargetAppsViewController.loadLocalApps` (`PXTargetAppsViewController.m`) | Coordinator test rejects ineligible targets before destructive work. |
| Smart location | `PXSmartLocationViewController.searchBarSearchButtonClicked:`, `handleUseLocationTapped:`, and `handleClearLocationTapped:` | `LocationSessionTests.m:testStationarySampleIsCoherentAndBounded`, `testCallbackValueObjectsExposeOneCoherentSyntheticSample` |
| Safe cleanup | `AppDataCleaner.clearKeychainForBundleID:includeAppFamily:completion:`, `clearWebDataForBundleID:error:`, and `clearDataForBundleID:completion:` | `tests/AppDataCleanerWebPlanTests.m:testRegistryContainerURLIsTheOnlyRawContainerSource`, `testRegistryLookupFailureReturnsItsConcreteErrorWithoutFallback` |
| VPN, domain, and native identifier legacy seams | `VPNDetectionBypass.x:PXVPNDetectionBypassShouldApply`, `DomainBlockingSettings`, `DomainBlockingHooks.x:shouldBlockDomain`, `Tweak.x:-[UIDevice identifierForVendor]` | No current ProjectX UIKit/true-device validation proves the reference-facing behavior. |

## Canonical screenshot inventory and functional parity matrix

### 1. Main dashboard — `58981bd776a45cf79b46ebc9c3470f2e.jpg`

| ID | Reference-visible control / behavior | Current ProjectX path and exact seam | Status, gap, and user-visible consequence | Recommended vertical slice |
| --- | --- | --- | --- | --- |
| D-01 | Green **Service Status** indicator | Home service cell is populated by `ProjectXViewController.serviceTitle`, `serviceDetail`, and `PXProjectXEnvironmentOperations.isServiceReady`. | `partial` — ProjectX reports daemon/profile readiness and generation failure, not the reference's generic service state. It is more diagnostic, but not a visual/status match. | Home status and diagnostics. |
| D-02 | Timestamp with **Refresh** affordance | `viewWillAppear:` calls `refreshEnvironmentSummary`; no explicit refresh control is present. | `missing` — users cannot intentionally refresh the dashboard on demand. | Home status and diagnostics. |
| D-03 | **Authorization** action | No account or authorization source path is permitted by `AGENTS.md` product constraint 1. | `intentionally different` — adding an authorization/account flow would contradict the local, direct-use product. | None; retain absence. |
| D-04 | `Device:` candidate summary (XS through 12 Pro-family values) | Home shows only the resolved active model in `refreshEnvironmentSummary`; settings has one selection through `handleModelTapped`. | `intentionally different` — ProjectX must not imply that arbitrary device candidates are independently usable. | Candidate-pool foundation, only after coherent-tuple validation exists. |
| D-05 | `Carrier:` candidate summary (French carrier examples) | Home resolves one carrier with `selectedCarrierRecordForIdentityDirectory:`; settings persists one stable carrier in `carrierSelectionViewController:persistSelectedCarrierIDs:`. | `intentionally different` — a broad carrier pool is not the current one-active-value policy. | Candidate-pool foundation. |
| D-06 | `OS:` candidate summary | `PXProfileGenerator.generateManifestWithInput:error:` consumes `input.iOSCatalog` and selects a model-compatible tuple. Home does not surface that catalog. | `backend-only` — compatible OS candidates exist at generation time but users cannot review or configure a pool. | Compatible system-version pool. |
| D-07 | `Network:` candidate summary (`4G`, `5G`, `WiFi`) | Home localizes one `PXEnvironmentNetworkType` with `localizedNetworkType:`; selector persists one value in `saveSelectedNetworkType:modelRecord:error:`. | `intentionally different` — ProjectX intentionally chooses one compatible network type, not several independently selectable ones. | Candidate-pool foundation. |
| D-08 | **Smart location** row showing coordinates | `PXSmartLocationViewController` supports search, current location, map long-press, clear, and commit through `saveConfiguredLocation:error:`. | `partial` — ProjectX has a richer manual location flow, but no reference-style compact coordinate-only action. | Location clarity and city selection. |
| D-09 | Active tuple / available-space text (`XS/16.7.3/4G/Free …`) | Home presents model, network, carrier, region, and location through `configureEnvironmentContent:forRow:`. `physicalDeviceSummary` has physical model and installed OS only. | `partial` — neither generated OS nor free-space is shown as this one coherent active tuple. | Home status and diagnostics. |
| D-10 | **Full clean** action | Generation calls `PXAutomaticEnvironmentCoordinator.runWithTargetBundleIdentifiers:completion:`; it activates, terminates selected targets, clears their planned data, then clears pasteboard and conditionally Safari. | `partial` — cleanup is correctly coupled to selected targets and generation, rather than an unrestricted one-tap broad wipe. There is no separately named full-clean action. | Safe maintenance summary. |
| D-11 | **History** action | The home only loads one `PXEnvironmentFailureReport` and `lastAppliedDate`; no list/history controller is routed. | `missing` — users cannot inspect a bounded generation/maintenance history. | Home status and diagnostics, with a bounded local event log rather than profile management. |
| D-12 | **Device information** action | `physicalDeviceSummary` is a noninteractive home row; model selector exposes model fields. No device-info controller is routed. | `partial` — information exists in fragments but lacks an accessible drill-in screen. | Home status and diagnostics. |
| D-13 | **Clear clipboard** action | `handleClearPasteboardTapped` confirms then calls `AppDataCleaner.clearClipboard`. | `complete` — this is a current, explicit home action. | Keep; add no wider cleanup scope. |
| D-14 | **Clear Keychain** action | `handleClearKeychainTapped` confirms then calls `clearKeychainForBundleID:includeAppFamily:completion:` for every explicitly selected target. | `complete` — the current flow is deliberately target-scoped, profile/generation checked, and excludes synchronizable items. | Keep; show scope/result detail if needed. |
| D-15 | **Clear Safari** action | `handleClearSafariTapped` calls `clearWebDataForBundleID:error:` for each selected target; Safari uses the dedicated plan in `webDataCleanupPlanForBundleID:error:`. | `complete` — current behavior is explicitly target-scoped rather than a global deletion. | Keep; show scope/result detail if needed. |
| D-16 | Local-app list disclosure and selected-count row | `handleTargetAppsTapped` opens `PXTargetAppsViewController`; `loadLocalApps` enumerates eligible local apps and returns scoped selections. | `complete` — this is a verified current home/settings path. | Keep. |
| D-17 | Visible installed-app row (**Vinted**, `lt.manodrabuzi...`) | `PXTargetAppsViewController.loadLocalApps` renders live eligible installed apps; no reference app name or bundle ID is hard-coded. | `intentionally different` — reference-specific private/third-party app data must not be copied. | Keep live data only. |

### 2. Fake-parameter settings — `0.jpg`

| ID | Reference-visible control / behavior | Current ProjectX path and exact seam | Status, gap, and user-visible consequence | Recommended vertical slice |
| --- | --- | --- | --- | --- |
| F-01 | **Device Model** row with `12 selected` | `PXSettingsHubViewController.handleModelTapped` opens `PXEnvironmentModelSelectorViewController`; save revalidates in `saveSelectedModelRecord:physicalModelRecord:hostGraphicsCapabilities:error:`. | `complete` — one active model is chosen only when compatible with immutable physical hardware. | Keep physical-model default prominent. |
| F-02 | **System Version** row with `17 selected` | Generator filters `input.iOSCatalog` by the selected model's `supportedIOSMajorVersions`. No settings row or persisted OS selection exists. | `backend-only` — generation can select a coherent OS, but no user-facing pool or single-choice control exists. | Compatible system-version pool. |
| F-03 | **Carrier** row with `3 selected` | `handleCarrierTapped` pushes `CarrierSelectionViewController`; push mode immediately persists exactly one ID. | `complete` — the selection is real, though it intentionally stores one stable carrier rather than the reference count. | Candidate-pool foundation before any count UI. |
| F-04 | **Network Type** row with `3 selected` | `handleNetworkTapped` opens `PXNetworkTypeSelectorViewController`; compatibility is checked by `isNetworkTypeCompatible:` and saved by `saveSelectedNetworkType:modelRecord:error:`. | `complete` — a real selected network is persisted and used by generation. | Candidate-pool foundation before any count UI. |
| F-05 | **BackupWhenClean** switch | No supported backup/restore/snapshot feature exists; `ProfileManifest`'s legacy migration backup directory is internal migration safety, not user backup. | `unsafe/unknown` — product constraints explicitly forbid app-data backup, restore, or snapshots. | None without a future product decision. |
| F-06 | **Anti-Jail-detection** switch | `JailbreakDetectionBypass.setEnabled:` persists a toggle, but `JailbreakDetectionBypass.setupBypass` is an explicit placeholder. | `placeholder/dead` — a stored preference is not evidence of an installed, complete bypass. | Security evidence gate; do not expose a new switch first. |
| F-07 | **VPN Hidden** switch | `VPNDetectionBypass.x:PXVPNDetectionBypassShouldApply` gates scoped-app interface sanitization on a preference and scope. No current settings-hub row routes to it. | `backend-only` — source contains a hook seam, but its complete behavior has not been verified through current UIKit or a true device. | Security evidence gate. |
| F-08 | **Network Fake** switch | The network selector writes `networkType`; the generator turns it into transport/radio values in `PXProfileGenerator.generateManifestWithInput:error:`. | `partial` — equivalent intent is a compatible value selector, not an unqualified on/off switch. | Candidate-pool foundation. |
| F-09 | **Carrier Fake** switch | Carrier persistence and generation use the carrier catalog, `PXTrustedCarrierPolicyStore`, and `PXProfileGenerator`. | `partial` — ProjectX uses an explicit, single carrier choice and derived region instead of a standalone switch. | Candidate-pool foundation. |
| F-10 | **Screen Fake (S)** switch | Model records include display fields, but model compatibility is enforced by `PXModelRecordIsHardwareCompatibleWithPhysicalRecord`. | `intentionally different` — screen data may not be independently spoofed because it would create impossible hardware identities. | None; preserve tuple coherence. |
| F-11 | **Screen Fake (M)** switch | Same seam as F-10; no independent display-model toggle is present. | `intentionally different` — separate screen variants would undermine the iPhone hardware invariant. | None; preserve tuple coherence. |
| F-12 | **KeyBypass** switch | No source symbol or user-facing route matching `KeyBypass` was found. | `missing` — do not infer behavior from the name or ship a no-op control. | Security evidence gate only if a concrete threat model is approved. |

### 3. Device-model pool — `09a28cabf7b4544eb6ad6729d5dfcb0e.jpg`

| ID | Reference-visible control / behavior | Current ProjectX path and exact seam | Status, gap, and user-visible consequence | Recommended vertical slice |
| --- | --- | --- | --- | --- |
| M-01 | Header count **Device Model [12/44]** | `PXEnvironmentPolicyStore.writePolicy:` persists only `modelIdentifier` plus `modelSelectionMode`; it has no candidate-model-array key. | `intentionally different` — count UI would claim a pool that the policy cannot persist or generate from. | Candidate-pool foundation. |
| M-02 | **SelAll** action | `PXEnvironmentModelSelectorViewController` retains one `selectedIdentifier` or `usesPhysicalDevice`. | `intentionally different` — select-all would permit incompatible models and conflict with the recommended **Use This Device** path. | Candidate-pool foundation, limited to compatible candidates. |
| M-03 | **Clear** action | Same one-model state as M-02; physical-device mode is the safe reset. | `intentionally different` — a blank model pool is not a safe equivalent of a coherent physical model. | Candidate-pool foundation, define an explicit reset to physical mode. |
| M-04 | Checkable model rows: **iPhone 15 Pro Max, 15 Pro, 15, 14 Pro, 14 Plus, 14, SE3, 13 Pro Max, 13 Pro, 13, 13 Mini, 12 Pro Max, 12 Pro, 12, 12 Mini**, and the partially visible next row | `PXEnvironmentModelSelectorViewController` displays searchable iPhone records and uses `compatibilityPresentationForIdentifier:` before delegating a one-model save. | `partial` — rows are real and incompatibility is explained, but the reference's arbitrary multi-selection semantics are not implemented or safe. | Compatible model candidate list after schema support. |

### 4. System-version pool — `c67f1cd38ae2e769afb6358ea66d8962.jpg`

| ID | Reference-visible control / behavior | Current ProjectX path and exact seam | Status, gap, and user-visible consequence | Recommended vertical slice |
| --- | --- | --- | --- | --- |
| O-01 | Header count **System Version [17/176]** | The pending policy allowed keys omit an OS field; `PXProfileGenerator.generateManifestWithInput:error:` receives an `iOSCatalog`. | `intentionally different` — no pending candidate set exists to count. | Candidate-pool foundation. |
| O-02 | **SelAll** action | The generator filters each OS tuple against `supportedIOSMajorVersions`. | `intentionally different` — selecting all would include OS/model combinations that must fail closed. | Compatible system-version pool. |
| O-03 | **Clear** action | There is no persisted OS choice/pool to clear. | `intentionally different` — clearing cannot silently discard the required compatible OS generation input. | Compatible system-version pool. |
| O-04 | Checkable version rows: **17.4.1, 17.4, 17.3.1, 17.3, 17.2.1, 17.2, 17.1.2, 17.1.1, 17.1, 17.0.3, 17.0.2, 17.0.1, 17.0, 16.7.7, 16.7.6**, and the partially visible next row | `PXProfileGenerator.generateManifestWithInput:error:` builds `compatibleIOSTuples` before choosing one. | `backend-only` — compatible tuple generation exists, but there is no current UIKit list. | Compatible system-version pool. |

### 5. Carrier pool — `c279cd7a319be3ebfed81138b544620c.jpg`

| ID | Reference-visible control / behavior | Current ProjectX path and exact seam | Status, gap, and user-visible consequence | Recommended vertical slice |
| --- | --- | --- | --- | --- |
| C-01 | Header count **Carrier [3/111]** | `TrustedCarrierPolicyTests.m:testExplicitPolicySaveRejectsEmptyAndPersistsOneStableCarrierID` proves the policy collapses to one ID. | `intentionally different` — a multi-carrier count would be false under the current schema. | Candidate-pool foundation. |
| C-02 | **SelAll** action | Push-mode `CarrierSelectionViewController` constructs `NSSet setWithObject:` for its selected carrier. | `intentionally different` — all carriers cannot be trusted candidates without tuple-level region/network validation. | Compatible carrier pool. |
| C-03 | **Clear** action | `PXTrustedCarrierPolicyStore` rejects empty trusted sets; the test above verifies it. | `intentionally different` — no carrier is invalid because region derives from carrier. | Compatible carrier pool with an explicit required default. |
| C-04 | Checkable country/carrier rows: **Thailand AIS, Thailand DTAC, Thailand TRUE-H, Korea SK, Korea KT, Malaysia U Mobile, Celcom, Digi, Maxis, China Mobile, China Unicom, China Telecom, Taiwan FarEasTone, Taiwan Mobile, Chunghwa Telecom** | `CarrierSelectionViewController.rebuildVisibleOptions` groups catalog options by country, but push navigation commits one compatible ID. | `partial` — country grouping and selectable catalog exist, but the user flow is an immediate single carrier selection. | Compatible carrier pool. |

### 6. Network-type pool — `179ab5f073b7b4abb886fa85d62090ea.jpg`

| ID | Reference-visible control / behavior | Current ProjectX path and exact seam | Status, gap, and user-visible consequence | Recommended vertical slice |
| --- | --- | --- | --- | --- |
| N-01 | Header count **Network Type [3/5]** | `PXEnvironmentPolicyStore` stores one `networkType` identifier. | `intentionally different` — ProjectX cannot truthfully present a selected network pool. | Candidate-pool foundation. |
| N-02 | **SelAll** action | `PXNetworkTypeSelectorViewController.isNetworkTypeCompatible:` rejects unsupported model/carrier combinations. | `intentionally different` — all values are not necessarily compatible, especially 5G. | Compatible network pool. |
| N-03 | **Clear** action | `saveSelectedNetworkType:modelRecord:error:` accepts a concrete compatible choice; no empty/automatic pool selection UI exists. | `intentionally different` — a clear action would leave the generated tuple underspecified. | Compatible network pool with a documented automatic option if required. |
| N-04 | Checkable rows: **2G, 3G, 4G, 5G, WiFi** | `PXNetworkTypeSelectorViewController` exposes WiFi, 5G, 4G, 3G, 2G, and None, one at a time. | `partial` — option coverage is present, but ProjectX adds an explicit offline value and preserves one compatible selected value. | Compatible network pool. |

### 7. Additional and location settings — `5c59e78b565f049920fc55daf3f6128c.jpg`

| ID | Reference-visible control / behavior | Current ProjectX path and exact seam | Status, gap, and user-visible consequence | Recommended vertical slice |
| --- | --- | --- | --- | --- |
| A-01 | **KernBypass** switch | No matching source symbol or current UIKit route was found. | `missing` — kernel-related behavior is high risk and must not be represented by a speculative switch. | Security evidence gate only. |
| A-02 | Backup-time automatic space cleanup switch | No supported user backup lifecycle exists; `AGENTS.md` forbids backup/restore/snapshots. | `unsafe/unknown` — implementation intent and deletion scope are unknown. | None without an explicit product decision. |
| A-03 | **Fix crash for fake high ver. (Games)** switch | No verified matching source seam was found. | `unsafe/unknown` — faking higher OS versions can create impossible model/OS/graphics tuples and unknown app behavior. | Security/compatibility evidence gate only. |
| A-04 | **Smart airplane** switch | No matching source symbol or current UIKit route was found. | `missing` — do not imitate the control without an understood and testable effect. | None until requirements exist. |
| A-05 | Prevent-system-update switch | No matching source symbol or current UIKit route was found. | `unsafe/unknown` — this is system-wide, high-risk behavior outside the current environment policy. | None until a product decision and safety review exist. |
| A-06 | **Original IDFV** switch | `Tweak.x:-[UIDevice identifierForVendor]` contains a scoped native-IDFV hook, but no current settings-hub control chooses original versus profile value. | `backend-only` — native IDFV handling is not a user-facing, verified “original IDFV” setting. | Identifier lifecycle evidence gate. |
| A-07 | **Fake Location** master switch / “Location By IP” subordinate label | Smart location commits a pinned location with `saveConfiguredLocation:error:` and can clear it; there is no master enable switch. | `partial` — the user can select/clear a coherent location, but not toggle a reference-like mode. | Location clarity and city selection. |
| A-08 | **Location By IP** switch | No IP geolocation provider, consent model, or source route was found. | `missing` — do not add network/provider lookup implicitly to a local-only tool. | None without privacy and product approval. |
| A-09 | **New IPGeo** button | No matching provider implementation was found. | `missing` — no verified behavior or provider contract exists. | None without privacy and product approval. |
| A-10 | **Old IPGeo** button | No matching provider implementation was found. | `missing` — no verified behavior or provider contract exists. | None without privacy and product approval. |
| A-11 | **Location By City** action | `PXSmartLocationViewController.searchBarSearchButtonClicked:` geocodes an entered address/city and `handleUseLocationTapped:` commits it. | `partial` — city search exists but is presented as map search, not a separate city-picker row. | Location clarity and city selection. |

## Pool semantics: reference versus ProjectX

The four reference picker headers and their `selected/total`, `SelAll`, and
`Clear` controls indicate **candidate pools** for later generated environments:
models, OS tuples, carriers, and network types are independently multi-selectable
in the reference UI. That is not what the current ProjectX settings schema means.

`PXEnvironmentPolicyStore.writePolicy:` allowlists `modelIdentifier`,
`modelSelectionMode`, `networkType`, `location`, location state, and applied-state
metadata. There is no candidate-model, candidate-OS, candidate-carrier, or
candidate-network array. Carrier state is separately constrained: settings push
mode commits one ID, and `TrustedCarrierPolicyTests` proves legacy multi-value
state is deterministically reduced to one stable carrier. The current model and
network selectors likewise retain one selected value.

The generator is the correct future boundary for a pool: it already filters model
records against immutable physical hardware, filters OS tuples against the chosen
model, selects eligible carriers with the pinned location in mind, and builds
network identity from the selected tuple. A future candidate feature must therefore
persist a policy of candidates, then **atomically choose and validate one complete
model/OS/carrier/region/network tuple at generation time**. It must never generate
by independently randomizing every visible picker. The physical device remains the
recommended safe one-click path; `DeviceModelManagerTests` enforces an iPhone-only
catalog and the model compatibility test enforces structured classification.

## Functional parity versus visual parity

No screenshot is visually `complete`, and visual similarity must not be used as
functional evidence.

| Surface | Functional observation | Visual direction if the corresponding safe slice is approved |
| --- | --- | --- |
| Home | ProjectX already has a grouped, dynamic-type-aware table, service diagnostics, target-app scope, and confirmed cleanup actions. | Retain native `UITableViewStyleInsetGrouped`, semantic system colors, localization, and accessibility identifiers. Do not copy the reference product name, French carrier data, Vinted data, compact ungrouped layout, or its low-information status row. |
| Settings and selectors | Current selectors use search, selected state, compatibility explanations, and one active value. | Keep the current system UITableView visual language. Candidate counts may be added only after the data model exists; counts must distinguish eligible, selected, and rejected candidates accessibly. |
| Location | ProjectX has map/search/current/clear/commit affordances rather than a pair of unexplained IP-provider buttons. | Preserve map-based provenance and mismatch messaging. A future city field should be an accessible refinement of this screen, not a copied reference control. |
| Security/legacy areas | Several legacy hooks and old controllers exist but are not current settings-hub features. | Do not reproduce green toggles that lack a verified result, test coverage, and true-device evidence. |

## FingerprintJS is not IDFV/IDFA

Reference device, OS, display, carrier, network, and location controls may affect
signal *inputs* that a web or SDK fingerprinting product observes. They are not an
implementation of FingerprintJS, and none should be described as producing a
FingerprintJS `visitorId`. A `visitorId` is a vendor-side/browser-side derived
identifier; native `IDFV`, `IDFA`, hardware UUID, and app-install identifiers are
separate platform values with different scopes and lifecycles.

ProjectX has three distinct, non-equivalent seams:

1. `Tweak.x` has scoped native IDFA and IDFV hooks, including an in-process IDFV
   cache. This is an identifier-lifecycle concern, not a FingerprintJS API.
2. `DomainManagementViewController.specifiers` contains legacy suggested domains
   `cdn.fingerprint.com` and `fingerprint.com`; `DomainBlockingHooks.x` can block
   configured domains for scoped apps at DNS, Foundation, CFNetwork, and WebKit
   layers. This is a legacy Preferences-based surface, not the current UIKit
   settings flow.
3. `DomainBlockingSettings` and `DomainBlockingHooks.x` contain permanent debug
   logging and have no current feature-level validation proving that blocking a
   service is safe for a selected target app.

Accordingly, FingerprintJS-relevant domain blocking is `backend-only` and
`unsafe/unknown` as a product feature until it is migrated behind current UIKit,
has explicit user intent and failure presentation, removes diagnostic leakage, and
is proven on a true device. It must not be conflated with F-12, A-06, or a native
UUID toggle.

## Dead, legacy, and incomplete paths to keep out of parity claims

- `JailbreakDetectionBypass.setupBypass` logs that it is a placeholder. The
  persisted `jailbreakDetectionEnabled` preference alone is not a complete feature.
- `DomainManagementViewController` is a `Preferences/PSSpecifier` legacy surface,
  not a route from `PXSettingsHubViewController`.
- `SecurityTabViewController` contains legacy domain-blocking and canvas-related
  controls, but this audit found no current settings-hub route and no true-device
  acceptance evidence for them.
- `AppDataCleaner.completeAppDataWipe:` is not the home generation path:
  `PXProjectXEnvironmentOperations.clearTargetBundleIdentifier:completion:` calls
  `clearDataForBundleID:completion:`. The reference's “full clean” must therefore
  not be claimed as broad, complete app-container cleanup.
- The reference `Authorization`, backup, unrestricted pools, and reference-branded
  app data are not gaps to fill. They are either product contradictions or
  insufficiently understood behaviors.

## Prioritized roadmap: coherent vertical slices

No implementation issues are created by this audit. Each slice below is a
dependency-ordered recommendation; it gives the designer boundary separately from
the coder boundary and specifies evidence required before a status can move.

### P0 — Candidate-policy and coherent-tuple foundation

- **Outcome:** Replace the implicit one-value-only policy limitation with a
  versioned, migration-safe candidate-policy model that can still represent the
  current physical-device and one-value paths.
- **Dependencies:** Existing immutable model classification, `PXProfileGenerator`,
  region-from-carrier schema-5 rule, and the one-stable-carrier migration behavior.
- **Coder boundary:** Define candidate arrays only for compatible catalog records;
  atomically choose/validate a single model, OS, carrier, region/time zone, and
  network tuple immediately before manifest activation. Reject empty or stale
  policy data and preserve the physical-device fallback. Do not launch targets.
- **Designer boundary:** Specify pool count semantics, selected/eligible/rejected
  states, a physical-device reset, and clear explanations for unavailable choices;
  no implementation of security toggles.
- **Risk:** High — schema migration and contradictory tuples can corrupt generated
  identity if validation is not centralized.
- **`TEST_MODE`:** deterministic unit fixtures for compatible/incompatible tuples,
  policy migration, empty pools, 5G/carrier mismatch, and iPhone-only catalog.
- **True-device evidence:** On each supported physical hardware class, choose a
  candidate set, generate once, inspect the active manifest for one coherent tuple,
  confirm the target was never launched, and confirm failure leaves no partial
  active identity.

### P1 — Compatible model, OS, carrier, and network pool UI

- **Outcome:** Expose the reference's useful pool concept only after P0, without
  reintroducing unrestricted multi-select behavior.
- **Dependencies:** P0 is required. Carrier changes must still derive region;
  5G needs compatible model and carrier support.
- **Coder boundary:** Wire each UIKit picker to candidate policy, revalidate when
  any dependent picker changes, and retain live single-value compatibility checks
  as the final guard. Do not allow iPad records or independent screen/GPU values.
- **Designer boundary:** Compose existing model, carrier, and network selector
  patterns; distinguish a candidate pool from the active generated tuple; provide
  search, VoiceOver state, and a visible incompatibility reason. Avoid copying the
  reference title/branding or dense list defects.
- **Risk:** High — a visually familiar `SelAll` can imply every option is safe.
- **`TEST_MODE`:** picker state transitions, accessibility values, count changes,
  policy persistence, and generator-only tuple validation.
- **True-device evidence:** Exercise physical fallback, a compatible custom pool,
  an incompatible model selection, an unsupported 5G combination, and a
  carrier/location mismatch; verify each result in the generated manifest.

### P1 — Home truthfulness and bounded maintenance

- **Outcome:** Add an intentional refresh action, show the active generated OS and
  a clear pending-versus-applied distinction, expose a read-only device detail,
  and provide a bounded local generation/maintenance report if product-approved.
- **Dependencies:** P0 only if active tuple fields are expanded; otherwise can
  proceed with existing manifest fields.
- **Coder boundary:** Source all displayed data from pending policy or active
  manifest with explicit labels; retain confirmation and target ownership for all
  cleanup. A “full clean” summary must state exactly which selected scopes were
  cleaned and must fail closed.
- **Designer boundary:** Extend the existing grouped home surface; design status,
  empty, failure, and history states. Do not add authorization, profile management,
  or a broad destructive action.
- **Risk:** Medium — presentation must never overstate cleanup completion or daemon
  readiness.
- **`TEST_MODE`:** refresh state, no-target state, failure-report persistence,
  event ordering, and safe cleaner-plan rejection cases.
- **True-device evidence:** Verify refresh updates state, every cleanup confirmation
  reports its selected target scope, Safari behavior is scoped, and generation
  terminates but never launches targets.

### P2 — Location clarity and city search

- **Outcome:** Make ProjectX's existing map/search flow clearer as a manual pinned
  location, optionally adding an explicit city-search entry point.
- **Dependencies:** Existing location policy validation and region/carrier mismatch
  communication.
- **Coder boundary:** Keep Core Location/geocoding user-driven, validate coordinates,
  persist only the selected result, and do not introduce an IP/provider call.
- **Designer boundary:** Improve provenance, pending/applied state, mismatch
  warnings, empty/error state, and VoiceOver announcements on the existing screen.
- **Risk:** Medium — a location must not silently claim to be IP-derived.
- **`TEST_MODE`:** coordinate bounds, clear-versus-pinned state, city geocode
  result selection, and coherent synthetic-location session tests.
- **True-device evidence:** Test search, current-location permission denied,
  map-pin selection, clear, and a carrier-country mismatch without network lookup.

### P3 — Security and legacy evidence gate

- **Outcome:** Decide whether any legacy security/domain/identifier behavior belongs
  in the supported product before exposing it.
- **Dependencies:** A written threat model, source ownership, RootHide hook review,
  current UIKit route decision, and a removal plan for permanent debug logging.
- **Coder boundary:** First prove exact scope, original-method fallback, preference
  propagation, error reporting, and rollback behavior. Do not create no-op toggles
  for KernBypass, KeyBypass, high-version compatibility, update blocking, airplane
  behavior, VPN hiding, or jailbreak detection.
- **Designer boundary:** No new switch scaffold until the coder evidence gate passes;
  then specify plain-language scope, enabled/disabled/error states, and a visible
  warning for app-impacting behavior.
- **Risk:** Very high — legacy hooks can alter network, attestation, identifiers, or
  system behavior in ways that are not currently understood.
- **`TEST_MODE`:** hook bundle filtering, preference cache invalidation, original
  fallback, logging review, and negative cases; no claim of complete parity from
  host-only tests.
- **True-device evidence:** Controlled, scoped-app validation with before/after
  network and native-identifier observations, failure recovery, and a regression
  check that unscoped apps retain original behavior.

## Coverage checklist

| Screenshot | Inventory rows | Complete | Partial | UI-only | Backend-only | Placeholder/dead | Missing | Intentionally different | Unsafe/unknown |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Main dashboard | 17 | 4 | 5 | 0 | 1 | 0 | 2 | 5 | 0 |
| Fake-parameter settings | 12 | 3 | 2 | 0 | 2 | 1 | 1 | 2 | 1 |
| Device-model pool | 4 | 0 | 1 | 0 | 0 | 0 | 0 | 3 | 0 |
| System-version pool | 4 | 0 | 0 | 0 | 1 | 0 | 0 | 3 | 0 |
| Carrier pool | 4 | 0 | 1 | 0 | 0 | 0 | 0 | 3 | 0 |
| Network-type pool | 4 | 0 | 1 | 0 | 0 | 0 | 0 | 3 | 0 |
| Additional/location settings | 11 | 0 | 2 | 0 | 1 | 0 | 5 | 0 | 3 |
| **Total** | **56** | **7** | **12** | **0** | **5** | **1** | **8** | **19** | **4** |

**Audit result:** all seven supplied screenshots and all 56 observed controls are
represented once in the canonical matrix. No application source, localization,
package/deployment state, or reference image was changed by this audit.

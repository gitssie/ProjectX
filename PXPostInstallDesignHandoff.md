# Post-install language, diagnostics, and logo handoff

## Language selector

- **Route:** Settings → Language → native Back.
- **Choices:** Follow System, 简体中文, English. The selected option has a standard checkmark and every row is a 44-point-or-larger immediate action; there is no Save, Done, restart, or device-global language change.
- **Scope:** This preference affects only `PXLocalizedString` / `PXLocalizedFormat` and ProjectX UI. It must never change device-global language, Profile regional identity, target-app spoofed locale, Carrier derivation, or the generated environment.
- **Refresh contract:** `PXSetUILanguagePreference` persists the UI-only preference, rebuilds its preferred localization bundle, then posts `PXUILanguagePreferenceDidChangeNotification` on the main thread. Each reachable controller observes it while visible, rebinds navigation titles/bar actions, reloads table/collection content, and posts a VoiceOver screen-changed notification. Recreate inactive controllers from the preference at presentation time.
- **Fallback:** Follow System uses normal main-bundle localization with English fallback. Explicit Chinese uses `zh-Hans`; explicit English uses `en`. Do not expose other language choices until resources exist.

## Environment-generation failure contract

### Immediate presentation

1. A generation result creates a `PXEnvironmentFailureReport` before presentation and writes an equivalent **redacted** record through `PXLog` using a coder-owned persistence seam.
2. The immediate localized alert includes plain-language summary, failed stage, affected target when present, concrete safe message, timestamp, and error reference. It never disappears because another controller is already presented: present over the current visible controller or after it dismisses.
3. Alert actions are **View details**, **Copy diagnostic information**, and **Close**. Copy output contains only stage, target Bundle ID when relevant, safe message, time, and reference.
4. The modal `PXEnvironmentFailureDetailsViewController` is scrollable and has a single Close dismiss action plus Copy. It lists summary followed by every individual failure; Dynamic Type, Chinese/English expansion, safe areas, and VoiceOver labels are required.

### Error mapping and redaction

| Validation family | Localized user-safe remediation |
|---|---|
| Incomplete model record | Choose a complete environment model. |
| Incompatible iOS tuple | Choose an iOS version/build compatible with the model. |
| Network/carrier mismatch | Choose compatible model, network type, and carrier. |
| Regional inconsistency | Choose a carrier with coherent region, language, and time zone. |
| Missing session metadata | Refresh pending environment information, then retry. |
| Identifier-format failure | Regenerate to repair invalid identifiers. |
| Unknown failure | Review pending configuration and retry; preserve reference for support-free local troubleshooting. |

Never show raw class names, filesystem paths, credentials, private keys, authorization headers, tokens, full device identifiers, or unbounded log content. Bundle identifiers are permitted only as the affected target technical name. A successful generation clears the last failure report; until then, Home's failed service/generation state remains tappable and reopens the same report.

## Logo asset contract

- `docs/logo.svg` remains the sole editable artwork source. It is never loaded at runtime on iOS 15.
- The rendered PNG uses the SVG's blue `#4263EB` as an opaque canvas behind its transparent outer artwork; geometry and supplied white/green marks are otherwise unchanged. This avoids transparent app-icon corners while preserving the authoritative visual design.
- `Icon.png` remains a 120×120 opaque PNG direct-bundle compatibility rendition. `Assets.xcassets/AppIcon.appiconset` contains 29, 40, 57, 58, 60, 80, 87, 114, 120, 180, and 1024 pixel PNG renditions, with `Contents.json` retaining the existing iPhone/marketing mappings.
- The only in-app brand placement is the About row's `Icon` image. No logo repetition, login, splash, or decorative branding was added to the seven-screen flow.

## Validation checklist

- Change each language choice on Home, Settings, Target Apps, model, network, carrier, and Smart Location; verify immediate text refresh, VoiceOver announcement, no restart, and no generated-environment change.
- Exercise one and multiple generation failures with model, iOS, carrier/network, regional, session, and identifier causes. Verify summary/stage/target/message/time/reference, non-dropping alert, reopen-from-Home, redacted copy, and success clearing behavior.
- Inspect English and zh-Hans resources for key and format parity; test largest Dynamic Type and compact iPhone 7 Plus height.
- Verify app icon and About-row logo against `docs/logo.svg` at all configured icon sizes, with no alpha corners or runtime SVG dependency.

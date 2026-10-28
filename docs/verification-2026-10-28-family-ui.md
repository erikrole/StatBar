# Monitor shared native interface · October 28, 2026

## Implemented

A shared identity header with explicit quiet/attention status, consistent section spacing and Settings footer, and Reduced Motion-aware attention transitions. The existing metric palette, native disclosures and compact overview remain.

The four apps use an identical `FamilyHeader.swift` and the same
[family guide](brand/FAMILY.md). Existing Icon Composer artwork is retained.
No container app, web UI or new shared runtime was introduced.

## Verification

- Debug suite: **57 passed, zero failures**.
- Developer ID-signed arm64 Release build succeeded with Hardened Runtime and
  debug entitlement injection disabled.
- `xcodegen generate` and `git diff --check` passed. Generated projects include
  the new views and build number.
- Reviewed the real 360 × 600 native view in dark appearance using a temporary, uniquely identified diagnostic build. CPU disclosure expanded correctly, and the Settings menu exposed Alerts, Open at login, automatic updates, version and Quit. The full diagnostic card render was also inspected. The temporary window harness is excluded from shipping source; its process skipped Login Items, updater checks and single-instance election.
- Signed **1.0.0 (6)** installed at `/Applications/StatBar.app`; strict deep
  signature verification passed, the signing requirement matched the prior app,
  and the installed process finished launching with display name **Monitor**.
- Bundle ID `com.erole.StatBar`, executable/app filename, data and preference paths,
  updater identity/feed and icon resources are unchanged.

Test/build logs and renders are ignored under `build/family-ui/`:
`debug-test.log` and `signed-release.log`. Test results were checked directly;
render success alone does not establish native interactions.

Typical commands (the widget suite also uses a pre-created preview output folder):

```sh
xcodegen generate
xcodebuild -project StatBar.xcodeproj -scheme StatBar -configuration Debug -destination 'platform=macOS' -derivedDataPath build/family-ui/DerivedData CODE_SIGNING_ALLOWED=NO test
xcodebuild -project StatBar.xcodeproj -scheme StatBar -configuration Release -destination 'generic/platform=macOS' -derivedDataPath build/family-ui/DerivedData CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY='Developer ID Application' DEVELOPMENT_TEAM=T26T3G8C7Q ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ARCHS=arm64 build
```

## Local installation and boundaries

Installation staged and verified each app, requested a normal quit, waited for
exit, preserved the prior bundle and swapped the verified copy into the same
path. No force-quit or data migration was used. Rollback bundles and per-app
installation manifests remain outside Git in
`~/Code Support/backups/mac-utility-family/2026-10-28-family-ui-144658/` and
`2026-10-28-family-ui-final/`. Manifests record the final source commit and installed
code hash after source handoff.

These are local trial builds. No Apple notarization upload, GitHub binary release
or public deployment was run. Full light/dark, Increase Contrast and VoiceOver
coverage is not claimed. Physical typing, TV control, Login Items changes,
real installers and automatic update/relaunch acceptance were not exercised by
this interface pass. Earlier release/runtime evidence applies to its recorded builds.

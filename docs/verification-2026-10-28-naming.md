# Monitor display-name adoption · October 28, 2026

## Change

StatBar now presents itself as **Monitor** in bundle metadata and user-facing copy.
The four apps adopt the same [family guide](brand/FAMILY.md): individual names,
simple dimensional object icons and native Mac controls, typography and spacing.
The existing layered Icon Composer artwork is retained.

Repository and checkout names, Xcode target/module, executable and app filenames,
bundle IDs, storage, preferences and update feeds remain stable. No app version
or build number changed. The README now records the current pinned AppUpdater
revision where the older text was stale.

## Verified

- `xcodegen generate` completed; the generated project had no changes.
- Debug suite succeeded: **57 tests reported, 0 skipped, zero failures**.
- Release build succeeded with `CODE_SIGNING_ALLOWED=NO`.
- Built Debug and Release Info.plists contain `CFBundleDisplayName = Monitor` and
  `CFBundleName = Monitor`, while preserving `com.erole.StatBar`, executable
  `StatBar` and icon resource name `StatBar`.
- Compared source Info.plist against the prior commit: only display/name keys
  changed. Project configuration, updater feed/ZIP configuration and icon artwork
  are unchanged. Shared guide contents match across all four repositories.
- Checked changed documentation links and `git diff --check`.
- Xcode emitted its expected App Intents metadata-extraction warning because this app has no AppIntents framework dependency; no compiler errors occurred.

Commands:

```sh
./scripts/check-macos.sh test
xcodebuild -project StatBar.xcodeproj -scheme StatBar -configuration Release -destination 'platform=macOS' -derivedDataPath build/naming-verification/DerivedData CODE_SIGNING_ALLOWED=NO build
```

Ignored local logs: `build/checks/test-20261028T191713Z-32289/xcodebuild.log` and
`build/naming-verification/release-build.log`. Initial sandboxed attempts could
not access Xcode caches/package downloads; the normal-access reruns above passed.

## Boundaries

No local app installation, notarization, binary release or deployment was run.
These unsigned build checks do not establish installed-name presentation,
Login Items/permission display, updater/relaunch migration, or a native UI review.
The renamed Release app has not been launched against the user's real data.
Historical release/runtime evidence in earlier reports applies to those older builds.

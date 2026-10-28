# StatBar app icon

`StatBar.icon` is the editable Icon Composer source. A graphite plotting display,
subtle grid, and three metric bars form separate SVG layers. The blue CPU,
purple GPU, and cyan network bars echo the app's metric palette. Light mode has
a pearl background; dark mode uses graphite with brighter metric highlights.

Open the `.icon` document in Icon Composer to change artwork, materials, or
appearance overrides. Both backgrounds and every foreground layer have explicit
light and dark gradients. Monochrome uses the system rendition. Keep layer art as
vectors and retain the shared square platform configuration.

`project.yml` includes the document as an app resource and sets
`ASSETCATALOG_COMPILER_APPICON_NAME` to `StatBar`. Run `xcodegen generate` after
project changes and retain the generated Xcode project. Xcode compiles
`Assets.car`, the fallback `StatBar.icns`, and the bundle icon metadata. The app's
existing menu bar presentation is independent of this application icon.

Verified October 28, 2026 with Xcode / Icon Composer 27.1: default, dark, and mono
renders, Developer ID Release build, named bundle icon and compiled resources,
and strict deep signature verification. Build evidence is local and ignored at
`build/icon-verification/native-refinement-release-build.log`. No app logic changed. Unit tests,
local installation, notarization, and distribution were not run for this change.

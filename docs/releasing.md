# Releasing StatBar

StatBar is distributed directly as a signed and notarized Apple Silicon ZIP
attached to a GitHub Release. Homebrew is intentionally deferred until the app
has a stable release cadence.

## Prerequisites

- Apple Developer Program membership.
- A **Developer ID Application** certificate and private key in the local
  keychain or in the release workflow's imported keychain.
- An App Store Connect API key authorized to submit notarization requests, or a
  local `notarytool` keychain profile.
- Xcode and XcodeGen.

If the checkout does not have a Developer ID Application identity, the release
script stops before archiving and explains what is missing.

## Local release

Use a keychain profile created for `notarytool`:

```sh
TEAM_ID="YOUR_TEAM_ID" \
NOTARY_PROFILE="StatBar-notary" \
./scripts/release-macos.sh
```

Or provide an App Store Connect API key directly:

```sh
TEAM_ID="YOUR_TEAM_ID" \
NOTARY_KEY_ID="YOUR_KEY_ID" \
NOTARY_ISSUER_ID="YOUR_ISSUER_ID" \
NOTARY_PRIVATE_KEY_PATH="/path/to/AuthKey_KEYID.p8" \
./scripts/release-macos.sh
```

An existing ASC CLI authentication profile is also supported, without copying its
credentials into a notarytool profile:

```sh
TEAM_ID="YOUR_TEAM_ID" \
ASC_PROFILE="YOUR_EXISTING_ASC_PROFILE" \
./scripts/release-macos.sh
```

Commit the reviewed source first. The script regenerates the Xcode project and
refuses a dirty checkout. The default output is a new
`.release/<version>-<source-sha>/` directory; an explicit `OUTPUT_DIR` must be empty.
Existing release evidence is never overwritten. If retrying a failed preparation,
choose a fresh output directory and retain the failed run's logs.
The archive builds from `git archive` of the captured commit, so subsequent
working-tree edits cannot alter the packaged source.

The script generates a Release archive, exports Developer ID-signed
`StatBar.app`, submits a ZIP to Apple's notary service, staples the ticket,
verifies a fresh extraction with codesign, stapler and Gatekeeper, and writes:

```text
.release/1.0.0-<source-sha>/StatBar-1.0.0-arm64.zip
.release/1.0.0-<source-sha>/StatBar-1.0.0-arm64.zip.sha256
.release/1.0.0-<source-sha>/release-manifest.json
```

The manifest records the exact committed source, version/build, architecture,
minimum macOS, signing team, accepted notarization submission and final ZIP digest.
The raw Apple response is retained as `notarization.json`. Packaging does not
publish a release or replace the installed app. The current preparation status is
in [1.0 readiness](1.0-readiness.md).

## GitHub release

No GitHub Actions release workflow is currently checked in. Pushing a tag alone
does not build or publish a release. GitHub publication is a separate step after
the local app is signed, notarized, stapled and verified; attach the final ZIP
and its checksum, and tag the exact source commit recorded in the release manifest.

Do not commit certificates, private keys, provisioning assets, or notarization
credentials.

## Verified release: 0.1.0 (build 1)

Built October 12, 2026 from source commit
`75e3d8c910cf41459dd6ac826814765350bd53a5`, for Apple Silicon and macOS 27 or later.
Artifacts are retained locally in the ignored `.release/0.1.0-75e3d8c/` directory:

- `StatBar-0.1.0-arm64.zip` — final app with its notarization ticket stapled.
- `StatBar-0.1.0-arm64.zip.sha256` — checksum for the final ZIP.
- `release-manifest.json` — source, version, signing and notarization evidence.

The archive and Developer ID export succeeded with Hardened Runtime and a secure
timestamp. The documented `StatBar-notary` profile was absent; the existing
`ASC Agent` profile was used through `asc notarization submit --wait` after
local Keychain approval, without copying or changing credentials. This was a
manual archive/export/ASC submission followed by the same stapling and ZIP
packaging steps as the release script.

Apple accepted submission `8abdccab-b09a-4ef3-81b7-677f521e57e2`. The final ZIP was
extracted and passed `codesign --verify --deep --strict`, `stapler validate`,
`spctl --assess --type execute` (Notarized Developer ID), and checksum verification.

SHA-256: `2a48078664f92b9706eabe702661ec661b2a6f9754a3b17a4ff6d3c7a27ae3f7`.

Published October 12, 2026 as [StatBar 0.1.0](https://github.com/erikrole/StatBar/releases/tag/v0.1.0).
Tag `v0.1.0` points to the exact source commit above. The signed ZIP and its
SHA-256 file are attached; both downloaded GitHub assets match the local files.
The same release was installed at `/Applications/StatBar.app` and launched,
replacing the development build; installed signature, ticket and Gatekeeper
verification passed.

The source validation and remaining hardware/UI verification limits are recorded
in [performance.md](performance.md).

## Verified updater release: 0.1.1 (build 2)

Published October 23, 2026 at [StatBar 0.1.1](https://github.com/erikrole/StatBar/releases/tag/v0.1.1). Source commit: `e35451c0088208307a1a92ce9f2a8bffd00debf5`. The app and its owned extensions/helpers require macOS 27.0 in Info.plist and Mach-O. The arm64 ZIP is Developer ID signed with Team `T26T3G8C7Q`, accepted by Apple notarization, stapled, and accepted by Gatekeeper after fresh extraction. ZIP/checksum/provenance digests match GitHub. Host tests: 53 reported, 0 skipped, zero failures. AppUpdater’s live download/verification path also passed for this public release.

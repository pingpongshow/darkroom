# Releasing DarkRoom

Signed, notarized DMGs and the Sparkle update feed are published as GitHub releases of this (public) repo.
Each release carries the DMG and `appcast.xml`; the app's feed URL is
`https://github.com/pingpongshow/darkroom/releases/latest/download/appcast.xml`.
Never put personal data in release notes.

## One-time setup (on the release Mac)

1. **Developer ID certificate.** In Xcode ▸ Settings ▸ Accounts, create a *Developer ID Application* certificate.
   Its name (`Developer ID Application: Your Name (TEAMID)`) is `DEVELOPER_ID`.
2. **Notarization credentials** (stored in the keychain, never in the repo):
   ```bash
   xcrun notarytool store-credentials darkroom-notary --apple-id <apple-id> --team-id <TEAMID>
   ```
   `darkroom-notary` is `NOTARY_PROFILE`. Use an app-specific password when asked.
3. **Sparkle signing key.** Build the app once so SwiftPM fetches Sparkle, then run its `generate_keys`
   (found under DerivedData `…/artifacts/sparkle/Sparkle/bin/generate_keys`). The private key stays in your
   login keychain; back it up (`generate_keys -x sparkle-private-key`) somewhere safe and offline.
   Put the printed **public** key in `project.yml` as `SPARKLE_PUBLIC_KEY`. Until it is set, update checks are
   disabled in the app.
4. **GitHub.** The repo must be public so the app can download updates anonymously. Sign in with `gh auth login`.

## Each release

1. Write release notes in `docs/ReleaseNotes/<version>.md` (no personal data).
2. Run the unit tests (`scripts/run-package-tests.sh`) and try the build.
3. Release:
   ```bash
   DEVELOPER_ID="Developer ID Application: … (TEAMID)" NOTARY_PROFILE=darkroom-notary scripts/release.sh 0.2.0
   ```
   Add `--dry-run` to build, sign and notarize without publishing (the DMG and appcast land in `build/`).

The script archives a Release build, verifies the signature, builds and signs a DMG, notarizes and staples it,
signs the update with Sparkle's EdDSA key, prepends an item to the appcast, and creates the GitHub release
`v<version>` in the releases repo with the DMG and appcast attached.

## CI (optional)

`.github/workflows/release.yml` runs the same script when started by hand (Actions ▸ Release ▸ Run workflow). It needs these repository secrets in
the repo: `DEVELOPER_ID_P12` (base64 certificate export), `DEVELOPER_ID_P12_PASSWORD`,
`DEVELOPER_ID`, `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD`, `SPARKLE_PRIVATE_KEY`.
Publishing uses the workflow's own token.

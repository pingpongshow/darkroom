# Releasing DarkRoom

Source stays in this private repo. Signed, notarized DMGs and the Sparkle update feed are published to the
public releases-only repo **pingpongshow/darkroom-releases** (DMGs, `appcast.xml`, release notes; never source
or personal data). The app's feed URL is
`https://github.com/pingpongshow/darkroom-releases/releases/latest/download/appcast.xml`.

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
4. **Releases repo.** Create the public repo `pingpongshow/darkroom-releases` (README only) and sign in with
   `gh auth login`.

## Each release

1. Write release notes in `docs/ReleaseNotes/<version>.md` (no personal data).
2. Run the tests (`scripts/run-package-tests.sh`, `scripts/run-ui-tests.sh`).
3. Release:
   ```bash
   DEVELOPER_ID="Developer ID Application: … (TEAMID)" NOTARY_PROFILE=darkroom-notary scripts/release.sh 0.2.0
   ```
   Add `--dry-run` to build, sign and notarize without publishing (the DMG and appcast land in `build/`).

The script archives a Release build, verifies the signature, builds and signs a DMG, notarizes and staples it,
signs the update with Sparkle's EdDSA key, prepends an item to the appcast, and creates the GitHub release
`v<version>` in the releases repo with the DMG and appcast attached.

## CI (optional)

`.github/workflows/release.yml` runs the same script on a tag push (`v*`). It needs these repository secrets in
the **private** repo: `DEVELOPER_ID_P12` (base64 certificate export), `DEVELOPER_ID_P12_PASSWORD`,
`DEVELOPER_ID`, `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD`, `SPARKLE_PRIVATE_KEY`,
`RELEASES_TOKEN` (fine-grained token with *contents: write* on the releases repo only).

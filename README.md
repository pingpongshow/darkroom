# DarkRoom

A native macOS client for [Immich](https://immich.app) with editing: browse and organise your whole
library, edit photos, Live Photos and videos, and round-trip to desktop editors — without modifying
the Immich server.

- **Platform:** Apple Silicon, macOS 26+
- **Server:** stock Immich (API generated from the supported release's OpenAPI spec)

## Layout

| Path | Contents |
|---|---|
| `App/` | macOS app (SwiftUI + AppKit) |
| `Packages/DarkRoomKit/` | `ImmichAPI` (generated client, media, live events), `DarkRoomCore` (accounts, library, editing, versions…) |
| `tools/generate-immich-api.py` | Regenerates `ImmichAPI/Generated` from an Immich OpenAPI spec |
| `TestServer/` | Stock Immich test server definition and seeding script |
| `scripts/` | Test-server tunnel, personal-data commit guard |

## Development

```sh
xcodegen generate                      # creates DarkRoom.xcodeproj from project.yml
scripts/test-server.sh tunnel          # test server at http://localhost:2283
(cd Packages/DarkRoomKit && swift test)
```

Local settings and credentials live only in the Keychain or in git-ignored files
(`Local.xcconfig`, `TestServer/.secrets/`). The pre-commit hook (`scripts/check-secrets.sh`) blocks
personal data and secrets.

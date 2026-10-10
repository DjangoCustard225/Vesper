# Development

Vesper targets iOS 27 and uses SwiftUI with a local `VesperCore` package. The app has no third-party Swift package dependencies.

## Project layout

```text
Vesper/
  App/                  Entry point, state, persistence, and feed models
  Components/           Shared artwork, poster, layout, and description views
  Features/
    Catalogs/           Add-on and TMDB catalog browsing
    Details/            Details, episodes, related titles, cast, and crew
    Discover/           Home shelves and hero carousel
    Library/            Saved titles and watch history
    Playback/           Stream selection and source cards
    Search/             Search presentation and provider results
    Settings/           Preferences, add-ons, credentials, and credits
  Assets.xcassets/       Canonical icon and white accent
Core/
  Sources/VesperCore/    Protocol models, clients, caching, routing, and subtitles
  Tests/VesperCoreTests/ Fixture-based tests
Scripts/                Generation, compilation, and cleanup
Vesper.xcodeproj/        Generated project and shared Vesper scheme
xtool.yml               Linux packaging configuration
```

## Xcode

Open `Vesper.xcodeproj`, select a signing team, and run the **Vesper** scheme. The bundle identifier is `app.vesper`.

After adding, moving, or removing Swift files, regenerate the project:

```sh
swift Scripts/GenerateXcodeProject.swift
```

`Vesper/Info.plist` supplies the app version and build number to the project generator and packaging tool. The About screen reads the packaged version at runtime.

## Linux IPA builds

Install xtool with a compatible Darwin SDK, then run:

```sh
bash Scripts/BuildIPA.sh
```

For environments where SwiftBuild IPC is restricted:

```sh
VESPER_NATIVE_BUILD=1 bash Scripts/BuildIPA.sh
```

Set `VESPER_PYTHON` to a Python 3 executable if needed. The optional adapter uses native SwiftPM compilation; xtool still plans resources and packages the app. Output: `xtool/Vesper.ipa`, unsigned.

## Tests

```sh
swift test --package-path Core
```

The restricted Linux configuration used for validation keeps build products outside the project:

```sh
XDG_CACHE_HOME=/tmp/vesper-test-cache swift test \
  --build-system native --cache-path /tmp/vesper-test-cache/swiftpm \
  --package-path Core --scratch-path /tmp/vesper-core-native
```

The 78 fixture tests cover protocol requests and filters, authentication, TMDB metadata and playback identity, crew and recommendations, seasons, pagination, artwork caching and concurrency, subtitle parsing, and VLC/Infuse handoff. Fixtures do not contact third-party providers. Library migration has also been checked with isolated filesystem fixtures.

iOS release compilation and IPA packaging pass. This Linux environment has no simulator; native rendering, transitions, touch and keyboard behavior, Keychain persistence, and real-player/provider interactions require device validation. Device loading performance has not been benchmarked.

## Assets and cleanup

The canonical icon is `Vesper/Assets.xcassets/AppIcon.appiconset/AppIcon.png`; Xcode and xtool share it. Generate or verify it with:

```sh
python3 Scripts/GenerateIcon.py
python3 Scripts/GenerateIcon.py --check
```

Remove generated build products, editor configuration, and staging files while preserving packaged IPAs:

```sh
bash Scripts/Clean.sh
```

## Implementation notes

- Artwork downloads coalesce and share HTTP/memory caches. Decoding and display preparation preserve the original image resolution.
- TMDB metadata and seasons cache for six hours; catalogs, searches, and recommendation pages cache for five minutes. Credential changes invalidate caches.
- Providers deliver partial results independently. Catalog pagination stops on repeated/final pages and offers retries for failures.
- TMDB owns movie/series metadata; add-ons can provide custom/live metadata and playback sources. IMDb matches provide compatible movie and episode IDs.
- The core supports `catalog`, `meta`, `stream`, and `subtitles`, including legacy manifest extras and SRT/WebVTT parsing. The external players manage actual subtitle presentation.
- Server-based torrent and header-proxy routing remains in the core. The app has no server configuration screen or embedded torrent engine; previously saved server values can still be read.
- Credentials use Keychain generic-password items with service `app.vesper` and `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. The TMDB account name is `tmdbCredential`.
- Library data uses an atomic, protected Application Support file. A legacy-folder migration preserves data already inside the same sandbox; it cannot import another bundle's sandbox.
- New callbacks use `vesper://`; the legacy scheme remains accepted for existing links. Both players receive the resolved URL, including authorization required by that source.

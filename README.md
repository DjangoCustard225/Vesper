<p align="center">
  <img src="Vesper/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="112" alt="Vesper app icon">
</p>

<h1 align="center">Vesper</h1>

<p align="center">
  Movies and series, in native Liquid Glass.<br>
  Immersive artwork · TMDB metadata · Stremio-compatible add-ons
</p>

<p align="center">
  <img src="https://img.shields.io/badge/iOS-27%2B-007AFF?style=flat-square" alt="Requires iOS 27 or later">
</p>

<p align="center">
  <a href="https://github.com/DjangoCustard225/Vesper/releases/download/0.1/Vesper.ipa">Download IPA · 0.1</a>
  · <a href="docs/DEVELOPMENT.md">Build from source</a>
</p>

Vesper is a SwiftUI app for iPhone and iPad. Discover movies and shows with TMDB, add your own providers, and play sources in VLC or Infuse.

## Features

- Immersive artwork, a customizable hero carousel, and soft scroll edges.
- Rich details with title logos, cast, crew, and related titles.
- Season selection and horizontal episode browsing.
- Search, a local library, and automatically loading catalogs.
- Stremio-compatible add-ons and external video players.

## Get started

1. Download the [0.1 release](https://github.com/DjangoCustard225/Vesper/releases/tag/0.1), sign the unsigned IPA, and install it on **iOS 27 or later**.
2. In **Settings → TMDB**, save and verify your [TMDB API key or Read Access Token](https://www.themoviedb.org/settings/api).
3. In **Settings → Add-ons → Add add-on**, install a provider using its manifest URL or `stremio://` link.
4. Install **VLC** or **Infuse**, choose it in **Settings → Player**, then open a title and tap **Play**.

Use providers with playable HTTP/HTTPS sources. Vesper has no built-in player or on-device torrent engine.

## Privacy

Credentials and add-on configuration are stored in **iOS Keychain**; your library stays on your device. Requests go directly to TMDB and your providers. No analytics, ads, or tracking SDKs.

## Development

Open `Vesper.xcodeproj` in **Xcode 27**, select your signing team, and run **Vesper**. Run core tests with:

```sh
swift test --package-path Core
```

See [Development](docs/DEVELOPMENT.md) for build instructions and [Releasing](docs/RELEASING.md) for packaging.

## Credits

Vesper is independent of Stremio. This product uses the TMDB API but is not endorsed or certified by TMDB.

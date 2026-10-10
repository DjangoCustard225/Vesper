<p align="center">
  <img src="Vesper/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="112" alt="Vesper app icon">
</p>

<h1 align="center">Vesper</h1>

<p align="center">
  A native iOS home for movies and series.<br>
  Liquid Glass. Immersive artwork. Your add-ons.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/iOS-27%2B-007AFF?style=flat-square" alt="Requires iOS 27 or later">
  <img src="https://img.shields.io/badge/UI-SwiftUI-F05138?style=flat-square" alt="Built with SwiftUI">
  <img src="https://img.shields.io/badge/release-0.1-24292F?style=flat-square" alt="Release 0.1">
</p>

<p align="center">
  <a href="https://github.com/DjangoCustard225/Vesper/releases/tag/0.1">Download 0.1</a>
  · <a href="#get-started">Get started</a>
  · <a href="docs/DEVELOPMENT.md">Build from source</a>
</p>

---

Vesper brings movie and series discovery, a personal library, and Stremio-compatible add-ons into a native SwiftUI app for iPhone and iPad. TMDB provides rich metadata and artwork; your add-ons provide playback sources. Open streams in VLC or Infuse.

## Made for browsing

| | |
| --- | --- |
| **Cinematic discovery** | Swipe through a configurable hero and browse compact, artwork-only shelves. Pull down to zoom the artwork. |
| **Rich title pages** | Integrated title logos, full descriptions, related titles, cast portraits, and crew details in native sheets. |
| **Series, organized** | Choose a season and scroll through horizontal episode cards with original-resolution artwork. |
| **Search on demand** | Open Search from the tab bar, find movies or shows, and open results in full-screen detail pages. |
| **Your add-ons** | Install, configure, enable, or remove Stremio-compatible providers. Catalogs load the next page automatically. |
| **Your library** | Save titles locally and revisit your collection. Choose the catalog featured in your home hero. |
| **External playback** | Choose VLC or Infuse, browse source cards, and long-press for a one-time player override. |

White accents, native controls, soft horizontal scroll edges, and a layered playback icon keep the interface consistent. Shared artwork caches preserve image quality, while providers deliver results independently.

## Get started

### 1. Install Vesper

Download **[Vesper.ipa](https://github.com/DjangoCustard225/Vesper/releases/download/0.1/Vesper.ipa)** from the **[0.1 release](https://github.com/DjangoCustard225/Vesper/releases/tag/0.1)**, sign it with your preferred signing tool, and install it on an iPhone or iPad running **iOS 27 or later**.

The release IPA is unsigned. You can also build and sign the app in Xcode; see the [development guide](docs/DEVELOPMENT.md).

### 2. Connect TMDB

Open **Settings → TMDB**, enter your API key or API Read Access Token, then tap **Save & verify**. Get credentials from your [TMDB account settings](https://www.themoviedb.org/settings/api).

### 3. Add your providers

Open **Settings → Add-ons → Add add-on**. Paste the provider's manifest URL, review it, and install. Configured provider URLs and `stremio://` installation links are supported.

Choose add-ons that return playable HTTP/HTTPS sources. TMDB provides metadata, not streams, and Vesper does not include an on-device torrent engine.

### 4. Choose a player

Install **VLC** or **Infuse** separately, then choose it in **Settings → Player**. Open a movie or episode, tap **Play**, and select a source.

## A few things to know

- A personal TMDB credential is required for default discovery and enriched movie/series details. Cinemeta is not used.
- Playback happens in an external player. The player manages subtitles and playback progress; Vesper does not import new progress automatically.
- Your library stays on your device. Stremio account sync, downloads, and a built-in player are not included.
- There is no streaming server configuration screen. Raw torrents and sources requiring a custom-header proxy need infrastructure outside a fresh Vesper installation.
- Version **0.1** uses bundle ID **`app.vesper`**. It installs separately from older builds using another bundle ID; credentials and library data do not automatically transfer between apps.

## Privacy

TMDB credentials and add-on configuration are saved in **iOS Keychain**. The TMDB key uses service `app.vesper` and account `tmdbCredential`; remove it in **Settings → TMDB → Remove API key**. Credentials are not embedded in the released app or committed to this repository.

The library is stored in a protected local file. Requests go directly to TMDB, enabled providers, artwork hosts, and selected playback sources. External players receive the selected source URL. Vesper includes no analytics, advertising, or tracking SDKs.

## Development

Open `Vesper.xcodeproj` in **Xcode 27**, select your signing team, and run the **Vesper** scheme. The app has no third-party Swift package dependencies; its protocol clients and fixtures live in the local `Core` package.

```sh
swift test --package-path Core
```

The current build passes **78 core tests** and iOS 27 release compilation. Native layout, animations, keyboard behavior, and real-provider playback require device validation; there is no iOS simulator in the Linux build environment.

See [Development](docs/DEVELOPMENT.md) for the project layout, Linux IPA builds, asset generation, and cleanup, or [Releasing](docs/RELEASING.md) for packaging and publication.

## Credits

Vesper is independent of Stremio. This product uses the TMDB API but is not endorsed or certified by TMDB. Attribution is also available in **Settings → About → Credits**.

Built around [Apple SwiftUI](https://developer.apple.com/xcode/swiftui/), the [Stremio add-on protocol](https://github.com/Stremio/stremio-addon-sdk/blob/master/docs/protocol.md), and the [TMDB API](https://developer.themoviedb.org/reference/intro/getting-started). The layered app icon and source-card design draw inspiration from Quby.

<p align="center">
  <img src="Vesper/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="112" alt="Vesper app icon">
</p>

<h1 align="center">Vesper</h1>

<p align="center">
  A native iOS content hub utilising Stremio add-ons.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/iOS-27%2B-007AFF?style=flat-square" alt="Requires iOS 27 or later">
</p>

<p align="center">
  <a href="https://github.com/DjangoCustard225/Vesper/releases/latest/download/Vesper.ipa">Download Vesper</a>
  &emsp;
  <a href="https://github.com/DjangoCustard225/Vesper/releases/latest/download/VesperGo.ipa">Download Vesper Go</a>
</p>

Browse with TMDB, save titles to your library, and watch in Vesper or with external video players like Infuse or VLC.

**Vesper Go** uses external players only and installs separately alongside Vesper.

## Screenshots

<p align="center">
  <img src="docs/screenshots/discover.png" width="160" alt="Discover movies and shows">
  &emsp;
  <img src="docs/screenshots/movie-details.png" width="160" alt="Movie details and related titles">
  &emsp;
  <img src="docs/screenshots/series-details.png" width="160" alt="Series details and episodes">
  &emsp;
  <img src="docs/screenshots/library.png" width="160" alt="Saved titles in the library">
</p>

## Features

- Browse movies and shows with immersive artwork and a customizable home carousel.
- Explore cast, crew, actor filmographies, and related titles.
- Pick a season and browse episodes.
- Search titles and save favorites to your library.
- Back up and restore your library.
- Watch in the built-in player with Liquid Glass controls, or use external video players like Infuse or VLC.
- Resume movies and episodes with Continue Watching, and mark titles watched or unwatched.
- Connect Trakt to sync watched history and scrobble built-in playback.

## Get started

1. Download the [latest release](https://github.com/DjangoCustard225/Vesper/releases/latest), sign the unsigned IPA, and install it on **iOS 27 or later**.
2. In **Settings → TMDB**, save and verify your [TMDB API key or Read Access Token](https://www.themoviedb.org/settings/api).
3. In **Settings → Add-ons → Add add-on**, install a provider using its manifest URL or `stremio://` link.
4. Open a title, tap **Play**, and choose a source. Select **mpv**, **AVPlayer**, **Infuse**, **Outplayer**, or **VLC** in **Settings → Video Player**.

Optionally connect your account in **Settings → Trakt** to sync watched history and scrobble built-in playback. Existing local history stays local; new watched/unwatched changes sync while connected. Trakt account limits apply. Your Vesper library is independent of your Trakt watchlist.

Use providers with playable HTTP/HTTPS sources. Vesper has no on-device torrent engine.

## Privacy

Credentials and add-on configuration are stored in **iOS Keychain**. Your library and resume positions stay on your device. Connecting Trakt optionally syncs watched history and shares built-in playback activity with your Trakt account; disconnecting keeps your local history. External players aren’t tracked. Requests go directly to TMDB, your providers, and Trakt when connected. Local diagnostics omit URLs and credentials. No analytics, ads, or tracking SDKs.

## Credits

Vesper is independent of Stremio. This product uses the TMDB API but is not endorsed or certified by TMDB.

Built-in playback uses [MPVKit’s libmpv](https://github.com/mpvkit/MPVKit) or [AetherEngine with AVPlayer](https://github.com/superuser404notfound/AetherEngine). License notices are available in Settings → About → Credits.

<p align="center">
  <img src="Vesper/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="112" alt="Vesper app icon">
</p>

<h1 align="center">Vesper</h1>

<p align="center">
  A native iOS content hub
</p>

<p align="center">
  <img src="https://img.shields.io/badge/iOS-27%2B-007AFF?style=flat-square" alt="Requires iOS 27 or later">
</p>

<p align="center">
  <a href="https://github.com/DjangoCustard225/Vesper/releases/latest/download/Vesper.ipa">Download Vesper</a>
  &emsp;
  <a href="https://github.com/DjangoCustard225/Vesper/releases/latest/download/VesperGo.ipa">Download Vesper Go</a>
</p>

Vesper brings movie and TV discovery, Stremio add-ons and playback together on iPhone and iPad. Find something to watch, save titles for later and pick up where you left off.

## Vesper or Vesper Go?

**Vesper** includes mpv and AVPlayer. You can also use Infuse, Outplayer or VLC. **Vesper Go** plays only through the external player you select. Both apps install separately.

For Dolby Vision and HDR playback, choose AVPlayer when the stream format supports it.

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

## What you can do

- Find movies and shows, explore cast and crew and browse related titles.
- Save titles, back up your library and continue watching later.
- Connect Trakt to sync watched history and built-in playback.

## Get started

1. Download the [latest release](https://github.com/DjangoCustard225/Vesper/releases/latest) for **iOS 27 or later**. The unsigned IPAs need signing before installation.
2. Add your TMDB API key in **Settings → TMDB**. [Get an API key](https://www.themoviedb.org/settings/api).
3. Add a provider in **Settings → Add-ons** with its manifest URL or `stremio://` link.
4. Open a title and tap **Play** to choose a source. Set your player in **Settings → Video Player**.

Connect Trakt in **Settings → Trakt** to import watch history and sync watched status. Playback in Vesper’s built-in players is reported to Trakt. External playback isn’t tracked.

Vesper needs providers with playable web streams. It doesn’t support torrent downloads.

## Privacy

Your library and resume points stay on your device. Credentials and add-on settings are stored in iOS Keychain. Trakt is optional. When connected, it syncs watch history and receives built-in playback activity. Vesper has no ads or analytics.

## Credits

Vesper is independent of Stremio. Built-in playback uses [MPVKit](https://github.com/mpvkit/MPVKit) or [AetherEngine](https://github.com/superuser404notfound/AetherEngine). Third-party notices are in **Settings → About → Credits**.

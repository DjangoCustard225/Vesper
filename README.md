<p align="center">
  <img src="Vesper/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="112" alt="Vesper app icon">
</p>

<h1 align="center">Vesper</h1>

<p align="center">
  Find your next movie or show, bring your Stremio add-ons, and watch your way.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/iOS-27%2B-007AFF?style=flat-square" alt="Requires iOS 27 or later">
</p>

<p align="center">
  <a href="https://github.com/DjangoCustard225/Vesper/releases/latest/download/Vesper.ipa">Download Vesper</a>
  &emsp;
  <a href="https://github.com/DjangoCustard225/Vesper/releases/latest/download/VesperGo.ipa">Download Vesper Go</a>
</p>

Vesper brings movie and TV discovery, your Stremio add-ons, and playback together on iPhone and iPad. Browse with TMDB, save titles for later, and pick up where you left off.

## Vesper or Vesper Go?

**Vesper** has built-in players—mpv and AVPlayer—and can also open streams in Infuse, Outplayer, or VLC. **Vesper Go** leaves out the built-in players and uses an external player instead. They install separately, so you can use either app or keep both.

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

- Find movies and shows, explore cast and crew, and see related titles.
- Browse seasons and episodes, then play a stream with your preferred player.
- Keep a library, back it up, and continue watching later.
- Connect Trakt to sync watched history and report built-in playback.

## Get started

1. Download the [latest release](https://github.com/DjangoCustard225/Vesper/releases/latest) and install it on **iOS 27 or later**. The release IPAs are unsigned and must be signed before installation.
2. Add your TMDB API key or Read Access Token in **Settings → TMDB**. [Get TMDB credentials](https://www.themoviedb.org/settings/api).
3. Add a provider in **Settings → Add-ons** with its manifest URL or `stremio://` link.
4. Open a title, tap **Play**, and choose a source. Pick your player in **Settings → Video Player**.

To sync watched history, connect Trakt in **Settings → Trakt**. Vesper can bring in your Trakt history and sync watched or unwatched changes. Playback in Vesper’s built-in players is scrobbled to Trakt; playback in external players isn’t tracked.

Vesper needs providers that offer playable web streams. It doesn’t include torrent downloads.

## Privacy

Your library and resume points stay on your device. Saved credentials and add-on settings are kept in iOS Keychain. Trakt is optional; when connected, it syncs watch history and receives built-in playback activity. Vesper has no ads or analytics.

## Credits

Vesper is independent of Stremio. It uses TMDB data, but TMDB does not endorse or certify the app. Built-in playback uses [MPVKit](https://github.com/mpvkit/MPVKit) and [AetherEngine](https://github.com/superuser404notfound/AetherEngine); third-party notices are in **Settings → About → Credits**.

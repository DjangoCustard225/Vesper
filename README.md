# Vesper

A simple JavaFX GUI for downloading media with [yt-dlp](https://github.com/yt-dlp/yt-dlp).

## Features

- Paste any URL and download at your chosen quality
- Quality options: 4K, 1440p, 1080p, 720p, 480p
- Live progress output in the text area

## Requirements

- Java with JavaFX
- `yt-dlp.exe` in the same directory (or on your PATH)

## Usage

1. Run the app
2. Paste a video URL
3. Pick a quality from the dropdown
4. Hit **Go**

## Notes

Currently targets Windows (`yt-dlp.exe`). To use on macOS/Linux, change the process call in `Vesper.java` to `yt-dlp` (no `.exe`).

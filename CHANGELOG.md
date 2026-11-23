# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- "Developed by c-na.dev" credit in the app header, About box and app menu (Visit c-na.dev), README and cover image.
- Links in the app now open in your default browser.

## [1.0.1] - 2026-11-23

### Fixed
- Release builds now run on the current macOS GitHub runner, so the DMG is published automatically. v1.0.0 was tagged but never released; it is identical apart from this fix.

## [1.0.0] - 2026-11-23

First public release.

### Added
- Native macOS app window (Swift + WebKit) with Dock icon, menu bar and Cmd+Q.
- Downloads every original photo and video from iCloud Photos to a folder you choose,
  using a bundled copy of icloudpd. Nothing else to install.
- Sign-in with Apple ID password and two-factor code from inside the app. The password
  is kept in memory only.
- Pause and resume at any time; files already downloaded are skipped and partly
  downloaded files continue where they stopped.
- Automatic retry after connection problems (up to 20 attempts).
- Keeps the Mac awake while downloading.
- Progress ring, item counts, speed and time-left estimate.
- Storage section: bars for this Mac's disk and the backup drive, backup size,
  whole-library size estimate and a warning when the drive is too small.
- Previews of the most recently downloaded photos.
- Options for videos, Live Photo videos, Advanced Data Protection and folder layout.
- Native folder picker, with a warning when the folder is on the Mac's internal disk.

[Unreleased]: https://github.com/sina-developer/icloud-photo-backup/compare/v1.0.2...HEAD
[1.0.2]: https://github.com/sina-developer/icloud-photo-backup/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/sina-developer/icloud-photo-backup/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/sina-developer/icloud-photo-backup/releases/tag/v1.0.0

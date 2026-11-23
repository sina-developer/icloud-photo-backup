# Security policy

## Reporting a vulnerability

Please **don't open a public issue** for security problems. Report them privately through
[GitHub's private vulnerability reporting](https://github.com/sina-developer/icloud-photo-backup/security/advisories/new).

Include what you found, how to reproduce it, and which version you used (shown at the bottom of
the app window). You should get a reply within a week.

Problems in icloudpd itself should be reported to the
[icloudpd project](https://github.com/icloud-photos-downloader/icloud_photos_downloader).

## Supported versions

Only the latest release gets security fixes.

## Design notes

- The Apple ID password is held in memory only and passed to icloudpd through a pseudo-terminal.
  It is never written to disk or logs.
- The local interface listens on `127.0.0.1` only. Requests need a random per-launch token and a
  local `Host` header, which protects against cross-site requests and DNS rebinding.
- The app is ad-hoc signed and not notarized. Releases are built by GitHub Actions from tagged
  commits, and each DMG comes with a SHA-256 checksum.

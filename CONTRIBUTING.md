# Contributing

Thanks for helping! Bug reports, fixes and improvements are all welcome.

## Reporting bugs

Open an [issue](https://github.com/sina-developer/icloud-photo-backup/issues/new/choose) with your
macOS version, the app version (bottom of the window), what you expected and what happened.
Include the **Activity log** if it's relevant, after removing your Apple ID and any other
personal details.

## Making changes

1. Fork the repo and create a branch.
2. Make your change. For interface or engine changes you can iterate quickly without building:
   `brew install icloudpd && python3 app/server.py`.
3. Build and try the real app: `scripts/build.sh`, then open `dist/iCloud Photo Backup.app`.
4. Add a line under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md).
5. Open a pull request describing what changed and how you tested it.

## Guidelines

- Keep the app self-contained: no runtime dependencies beyond what the build bundles.
- `app/server.py` uses only the Python standard library.
- Never log or store the Apple ID password.
- Keep the interface usable for non-technical people: plain words, clear next steps.
- Don't test with real accounts in automated tests or CI.

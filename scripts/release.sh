#!/bin/bash
# Prepares a release: bumps VERSION, moves "Unreleased" notes in CHANGELOG.md
# under the new version, commits, and creates the tag. Pushing the tag makes
# GitHub Actions build the DMG and publish the GitHub Release.
#
# Usage: scripts/release.sh 1.2.0
set -euo pipefail
cd "$(dirname "$0")/.."

NEW="${1:-}"
if ! [[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: scripts/release.sh X.Y.Z   (current: $(cat VERSION))" >&2
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "Commit or stash your changes first." >&2
  exit 1
fi
if git rev-parse "v$NEW" >/dev/null 2>&1; then
  echo "Tag v$NEW already exists." >&2
  exit 1
fi
if ! awk '/^## \[Unreleased\]/{f=1;next} /^## \[/{f=0} f && /[^[:space:]]/{found=1} END{exit !found}' CHANGELOG.md; then
  echo "CHANGELOG.md has no notes under '## [Unreleased]'. Add them first." >&2
  exit 1
fi

TODAY="$(date +%Y-%m-%d)"
echo "$NEW" > VERSION
# Insert the new version heading right below "## [Unreleased]".
awk -v v="$NEW" -v d="$TODAY" '
  /^## \[Unreleased\]/ { print; print ""; print "## [" v "] - " d; next }
  { print }
' CHANGELOG.md > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md

git add VERSION CHANGELOG.md
git commit -m "Release v$NEW"
git tag -a "v$NEW" -m "v$NEW"

echo
echo "Release v$NEW prepared. Publish it with:"
echo "  git push && git push origin v$NEW"

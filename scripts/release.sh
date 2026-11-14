#!/bin/zsh
# Publishes a new version: sets it in pubspec.yaml, commits, tags vX.Y.Z and
# pushes. The tag starts .github/workflows/release.yml, which builds the Mac
# DMG and the Windows installer and attaches them to a GitHub Release. The
# website's download buttons always point at the latest release.
#
#   scripts/release.sh 1.0.1
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:-}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: scripts/release.sh X.Y.Z   (current: $(grep '^version:' pubspec.yaml))" >&2
  exit 1
fi
if git rev-parse "v$version" >/dev/null 2>&1; then
  echo "v$version already exists" >&2
  exit 1
fi

current=$(sed -n 's/^version: *//p' pubspec.yaml)
build=${current#*+}
[[ "$build" == "$current" ]] && build=0
if [[ "${current%%+*}" != "$version" ]]; then
  sed -i '' "s/^version: .*/version: $version+$((build + 1))/" pubspec.yaml
  git add pubspec.yaml
  git commit -m "Release $version"
fi
git tag -a "v$version" -m "Winter $version"
git push origin HEAD "v$version"
echo "Building v$version: https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/actions"

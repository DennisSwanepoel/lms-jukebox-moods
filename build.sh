#!/bin/sh
# Builds the installable plugin zip and repo.xml (Linux, macOS or WSL).
#
# Usage: ./build.sh <base-url> [homepage-url]
#   base-url      where the zip will be downloadable, e.g.
#                 https://github.com/<user>/<repo>/releases/download/v0.1.7
#   homepage-url  optional project page, e.g. https://github.com/<user>/<repo>
#
# The zip holds the contents of JukeboxMoods/ at its root (install.xml at the
# top level) and carries the version in its name, as LMS requires.
set -e
cd "$(dirname "$0")"
VERSION=$(sed -n 's:.*<version>\(.*\)</version>.*:\1:p' JukeboxMoods/install.xml)
ZIP="JukeboxMoods-$VERSION.zip"
BASEURL=${1:?Usage: ./build.sh <base-url> [homepage-url]}
BASEURL=${BASEURL%/}
LINK=""
[ -n "$2" ] && LINK="
			<link>$2</link>"

rm -f "$ZIP"
(cd JukeboxMoods && zip -qr "../$ZIP" . -x '*.DS_Store')
SHA=$(sha1sum "$ZIP" | cut -d' ' -f1)

cat > repo.xml <<XML
<?xml version="1.0"?>
<extensions>
	<details>
		<title lang="EN">Jukebox Moods</title>
	</details>
	<plugins>
		<plugin name="JukeboxMoods" version="$VERSION" minTarget="8.0" maxTarget="*">
			<title lang="EN">Jukebox Moods</title>
			<desc lang="EN">Keeps the music playing when the queue runs out, using tag-based moods you can switch on the fly. Works with Don't Stop The Music. Inspired by Silverjuke.</desc>
			<category>playlists</category>
			<creator>Dennis Swanepoel</creator>$LINK
			<url>$BASEURL/$ZIP</url>
			<sha>$SHA</sha>
		</plugin>
	</plugins>
</extensions>
XML

echo "Built $ZIP (sha1 $SHA) and repo.xml pointing at $BASEURL/$ZIP"

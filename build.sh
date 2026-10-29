#!/bin/sh
# Builds the installable plugin zip and a repo.xml for Settings > Manage Plugins.
# Usage: ./build.sh https://raw.githubusercontent.com/<you>/<repo>/main
set -e
cd "$(dirname "$0")"
VERSION=$(sed -n 's:.*<version>\(.*\)</version>.*:\1:p' JukeboxMoods/install.xml)
ZIP="JukeboxMoods-$VERSION.zip"
BASEURL=${1:-https://example.com/jukeboxmoods}

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
			<desc lang="EN">Tag-based mood profiles for Don't Stop The Music, inspired by Silverjuke.</desc>
			<creator>Dennis Swanepoel</creator>
			<url>$BASEURL/$ZIP</url>
			<sha>$SHA</sha>
		</plugin>
	</plugins>
</extensions>
XML

echo "Built $ZIP (sha1 $SHA) and repo.xml pointing at $BASEURL/$ZIP"

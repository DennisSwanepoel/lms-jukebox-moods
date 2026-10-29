# Jukebox Moods for Lyrion Music Server

Jukebox Moods keeps the music playing when a player's queue runs out, using tracks from a **mood** you define, such as "Sunday Morning" or "Braai". It brings the AutoPlay "music selections" of the Silverjuke desktop jukebox to [Lyrion Music Server](https://lyrion.org) (LMS).

It plugs into LMS's built-in **Don't Stop The Music** feature. You can still queue your own tracks at any time; when they run out, the active mood takes over again.

Inspired by Silverjuke; not affiliated with the Silverjuke project. Requires LMS 8.0 or later. Licensed under the GNU GPL v2 or later.

## Features

- **Moods built from rules.** Each rule is a field, an operator and a value, for example *genre is Jazz*, *year between 1965 and 1979* or *rating at least 4*. A mood matches all or any of its rules and can have exclusion rules. A mood with no rules uses the whole library.
- **Your own file tags.** Switch on "Scan additional tags" and every extra tag in your files (MOOD, ENERGY, GROUPING, ...) appears in the rule field list. For tags holding several values, such as `Chilled;Summer`, use the *contains* rule.
- **Switch moods on the fly** from *My Apps > Jukebox Moods* in the web interface, Material Skin or controller apps, or from the CLI.
- **Fallbacks.** When a mood runs dry it can switch to another mood, or choose **Don't Stop the Music** (go back to the mood you picked and keep playing, with repeats if needed; the default), **Restart Current Mood** (replay the mood that's playing), **Song Mix** (random tracks from the whole library) or **Do Nothing** (stop when the queue ends).
- **Repeat protection** (optional): skip tracks played within the last N minutes.

## Installation

### From a plugin repository (recommended)

1. In LMS, go to *Settings > Manage Plugins*.
2. Under *Additional repositories*, add the URL of this project's `repo.xml` (see [Releasing](#building-and-releasing)) and save.
3. Enable **Jukebox Moods** and restart LMS.

### Manual install (for testing)

1. Open *Settings > Information* in LMS and note a plugin folder on persistent storage. Don't use a folder ending in `InstalledPlugins`, which LMS manages itself.
2. Copy the `JukeboxMoods` folder from this repository into it, so that `JukeboxMoods/install.xml` sits directly inside the plugin folder.
3. Restart LMS.

On piCorePlayer, use a folder under `/mnt/...`; system folders live in RAM and are wiped at reboot.

## Getting started

The plugin's settings page (*Settings > Plugins > Jukebox Moods*) shows these steps and which players are already set up.

1. **Optional:** tick *Scan additional tags from my music files*, save, and reload the page when the scan has finished.
2. **Create a mood**, add rules, check them with *Count matching tracks*, choose what happens when it runs dry, and save.
3. **Switch it on per player:** in the player's settings, set *Don't Stop The Music* to **Jukebox Moods (active mood)**, and make sure repeat is off. A player must be connected to LMS for its settings to appear.
4. **Choose a mood** from *My Apps > Jukebox Moods*.

## Using it

LMS asks for more tracks whenever fewer than two are lined up after the one it is loading, so two or three upcoming tracks is normal. *Tracks per top-up* controls how many are added each time.

Switching a mood from the menu offers three modes: **Switch now** (replace queued mood tracks), **Switch after the current queue**, and **Clear queue and play this mood**.

The mood you pick in My Apps stays your choice: fallbacks only change which mood is currently playing, and the "Don't Stop the Music" fallback returns to it.

A mood runs dry when all its matching tracks are already in the playlist (played or upcoming), are blocked by repeat protection, or nothing matches. LMS never adds a track that is already in the playlist, so "keep playing this mood" removes earlier, already-played copies before re-queuing them.

### CLI and JSON-RPC

```
<playerid> jukeboxmoods moods
<playerid> jukeboxmoods activate mood:Braai mode:replace     (modes: queue, replace, play)
jukeboxmoods count profile:<mood as JSON>
jukeboxmoods reindex
```

For example, from Home Assistant or a script:

```
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"id":1,"method":"slim.request","params":["aa:bb:cc:dd:ee:ff",["jukeboxmoods","activate","mood:Braai","mode:replace"]]}' \
  http://<lms-host>:9000/jsonrpc.js
```

## Troubleshooting

- **Music stops, or random tracks play instead of my mood:** the mood and its fallbacks had no usable tracks, so the chain ended in Do Nothing or Song Mix. `server.log` contains a warning listing, per mood, how many tracks matched, how many were blocked by repeat protection and how many were already in the playlist.
- **More detail:** set the `plugin.jukeboxmoods` log category to Debug (*Settings > Advanced > Logging*). *Settings > Information* shows where the log file is.
- **File tags missing:** reload the settings page after the scan, or tick *Rebuild the whole tag index when I save*. The index lives in `jukeboxmoods.db` in the LMS cache folder and is safe to delete.

## Project layout

```
JukeboxMoods/                 the plugin (this folder is what LMS loads)
  install.xml                 plugin manifest: id, version, entry module
  strings.txt                 user interface text
  Plugin.pm                   entry point: DSTM provider, mood switching, menu, CLI
  Selector.pm                 rule engine: rules -> SQL -> track sets -> random pick
  TagIndex.pm                 reads extra file tags into its own SQLite index
  Settings.pm                 settings page handler
  HTML/EN/plugins/JukeboxMoods/settings/basic.html   settings page and mood editor
build.ps1, build.sh           build the plugin zip and repo.xml (Windows / Linux, macOS)
CHANGELOG.md, LICENSE
```

Each module starts with a comment block explaining its role, and every function is commented. A fuller technical specification is kept separately by the maintainer.

## Building and releasing

Use `build.ps1` on Windows or `build.sh` on Linux, macOS or WSL. Both create `JukeboxMoods-<version>.zip` and a matching `repo.xml`.

1. Raise `<version>` in `JukeboxMoods/install.xml` and add an entry to `CHANGELOG.md`.
2. Build, pointing at the GitHub release the zip will be attached to:
   - Windows: `powershell -ExecutionPolicy Bypass -File build.ps1 -BaseUrl https://github.com/<user>/<repo>/releases/download/v<version> -Homepage https://github.com/<user>/<repo>`
   - Linux/macOS: `./build.sh https://github.com/<user>/<repo>/releases/download/v<version> https://github.com/<user>/<repo>`
3. Create a GitHub release with tag `v<version>` and attach the zip.
4. Commit the new `repo.xml` to the main branch. LMS offers the update on its next check.

The repository URL users add in LMS is `https://raw.githubusercontent.com/<user>/<repo>/main/repo.xml`.

The built zip and `repo.xml` are listed in `.gitignore`; publish them as release assets or commit them deliberately.

## Contributing

Issues and pull requests are welcome. Please keep changes in line with how LMS plugins work, test on a real LMS server with Debug logging on, and update `CHANGELOG.md`.

## Licence

GNU General Public License v2 or later, the same as Lyrion Music Server. See `LICENSE`.

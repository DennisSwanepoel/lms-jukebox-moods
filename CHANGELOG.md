# Changelog

All notable changes to Jukebox Moods. Versions follow `<version>` in `JukeboxMoods/install.xml`.

## 0.1.7
- Fallback options renamed and explained in the Moods help bubble: Don't Stop the Music (back to the mood you picked), Restart Current Mood, Song Mix, Do Nothing, or any other mood.
- Song Mix is now provided by the plugin (random tracks from the whole library).
- New "Do Nothing" option: playback really stops when the queue ends. To make this possible the provider is now registered as PLUGIN_RANDOM_JUKEBOXMOODS, which stops LMS adding its own Song Mix when the plugin returns nothing; players using the old name are switched over automatically.
- Moods set to the old "Let LMS play a Song Mix" are moved to the new Song Mix option.

## 0.1.6
- New fallback option "Go back to the mood I picked (keep playing)", now the default. When a fallback chain runs out, the plugin returns to the mood you picked in My Apps and keeps playing from it, with repeats if needed, so the music never drops out to LMS's Song Mix.
- The plugin remembers the mood you picked separately from the mood a fallback switched to; My Apps shows both after a fallback.
- Moods still set to the old default (Song Mix) are moved to the new option once on upgrade.

## 0.1.5
- Settings page: new collapsible "Getting started" box with setup steps, showing which connected players have Jukebox Moods switched on in Don't Stop The Music.
- Code comments throughout, plus LICENSE, CHANGELOG and .gitignore for publishing on Git.

## 0.1.4
- Repeat protection is now set in minutes (1 minute to 90 days). Existing hour values are converted automatically.

## 0.1.3
- "When this mood runs dry" now offers: switch to another mood, keep playing this mood (repeats allowed), or let LMS play a Song Mix.
- Tracks already anywhere in the playlist are excluded, matching how Don't Stop The Music de-duplicates. Fixes fallback moods being skipped in favour of Song Mix.
- A warning with per-mood counts is logged whenever a top-up finds no tracks.
- File tag names no longer show track counts in the rule field list.

## 0.1.2
- File tags are discovered automatically: every extra tag in your files appears in the rule field list, no typing of tag names.
- Removed the multi-value separator setting; use the "contains" rule instead.
- File tag explanation moved into the setting's help bubble.
- Removed the 0.1.1 duplicate-request guard, which caused LMS to fall back to Song Mix.

## 0.1.1
- "Scan additional tags" became an explicit on/off switch.
- Attempted fix for duplicate top-ups (replaced in 0.1.2).

## 0.1.0
- First version: moods with include/exclude rules, file tag index, Don't Stop The Music provider, mood switching from My Apps and the CLI, repeat protection, fallback moods.

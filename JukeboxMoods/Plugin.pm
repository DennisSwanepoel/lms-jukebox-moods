package Plugins::JukeboxMoods::Plugin;

# =============================================================================
# Jukebox Moods - tag-based mood profiles for Lyrion Music Server (LMS)
# Inspired by the AutoPlay "music selections" in Silverjuke.
#
# Copyright (C) 2026 Dennis Swanepoel and contributors.
# Licensed under the GNU General Public License v2 or later (see LICENSE),
# the same licence as Lyrion Music Server.
#
# This is the plugin's entry point. It is responsible for:
#   * preferences and their defaults/migrations
#   * registering as a provider for LMS's "Don't Stop The Music" (DSTM)
#     feature, which asks us for tracks whenever a player's queue runs low
#   * choosing tracks from the player's active mood, and walking a mood's
#     fallback chain when it runs dry
#   * the "Jukebox Moods" entry in My Apps for switching moods on the fly
#   * CLI / JSON-RPC commands (jukeboxmoods ...)
#   * menu entries and commands for events (the engine itself is Events.pm)
#   * validating mood definitions coming from the settings page
#
# Related modules:
#   Selector.pm  - turns a mood's rules into a set of tracks and picks from it
#   TagIndex.pm  - reads extra file tags (MOOD, GROUPING, ...) into its own index
#   Events.pm    - events: planned sequences of moods, started manually or on a schedule
#   Settings.pm  - the settings page handler (HTML in HTML/EN/plugins/...)
#
# Terminology: in the code a mood is called a "profile"; the user interface
# calls it a mood. A "top-up" is one DSTM request for more tracks.
# =============================================================================

use strict;
use warnings;

use base qw(Slim::Plugin::OPMLBased);

use Scalar::Util qw(blessed);
use List::Util qw(max);
use POSIX ();
use JSON::XS::VersionOneAndTwo;

use Slim::Control::Request;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);

use Plugins::JukeboxMoods::Events;
use Plugins::JukeboxMoods::Selector;
use Plugins::JukeboxMoods::TagIndex;

# Our name in LMS's Don't Stop The Music provider list (a strings.txt token).
#
# Why it starts with PLUGIN_RANDOM: when a provider returns no tracks, LMS's
# DSTM plugin adds its own Song Mix, *unless* the provider's token starts with
# PLUGIN_RANDOM (it assumes such a provider is already a random mix). Using
# this prefix lets the "Do Nothing" fallback really stop at the end of the
# queue. The plugin supplies its own Song Mix for the "Song Mix" fallback.
use constant DSTM_TOKEN      => 'PLUGIN_RANDOM_JUKEBOXMOODS';
use constant OLD_DSTM_TOKEN  => 'PLUGIN_JUKEBOXMOODS_DSTM';   # used up to 0.1.6; migrated

# Fallback values (what a mood does when it runs dry). Anything else is the
# id of another mood to switch to.
use constant CHOSEN_FALLBACK  => '__chosen__';    # "Don't Stop the Music": back to the mood I picked
use constant REPEAT_FALLBACK  => '__repeat__';    # "Restart Current Mood": replay it, repeats allowed
use constant SONGMIX_FALLBACK => '__songmix__';   # "Song Mix": random tracks from the whole library
use constant STOP_FALLBACK    => '__stop__';      # "Do Nothing": add nothing; playback ends with the queue
my %SPECIAL_FALLBACK = map { $_ => 1 } (CHOSEN_FALLBACK, REPEAT_FALLBACK, SONGMIX_FALLBACK, STOP_FALLBACK);

my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.jukeboxmoods',
	defaultLevel => 'WARN',
	description  => 'PLUGIN_JUKEBOXMOODS',
});

my $prefs = preferences('plugin.jukeboxmoods');

$prefs->init({
	profiles         => [],
	tracksPerTopup   => 2,
	repeatProtect    => 0,
	repeatMinutes    => 60,
	announceFallback => 1,
	customTags       => '',
});

$prefs->setValidate({ validator => 'intlimit', low => 1, high => 20 },   'tracksPerTopup');
$prefs->setValidate({ validator => 'intlimit', low => 1, high => 129600 }, 'repeatMinutes');   # 1 minute to 90 days

# 0.1.4: the repeat window moved from hours to minutes
if (defined(my $hours = $prefs->get('repeatHours'))) {
	$prefs->set('repeatMinutes', $hours * 60);
	eval { $prefs->remove('repeatHours') };
}

# File-tag scanning is an on/off switch (0.1.1+). Installs that had listed
# tags under the old "Custom tags" field keep scanning.
unless (defined $prefs->get('scanCustomTags')) {
	$prefs->set('scanCustomTags', $prefs->get('customTags') ? 1 : 0);
}

# 0.1.6: "Go back to the mood I picked" became the default end of a fallback
# chain. Moods still set to the old default (Song Mix) are moved to it once.
unless ($prefs->get('migratedChosenFallback')) {
	my $moods = $prefs->get('profiles');
	if (ref $moods eq 'ARRAY' && grep { !($_->{fallback}) } @$moods) {
		$_->{fallback} ||= CHOSEN_FALLBACK for @$moods;
		$prefs->set('profiles', $moods);
	}
	$prefs->set('migratedChosenFallback', 1);
}

# 0.1.7: an empty fallback used to mean "let LMS play a Song Mix"; that is now
# the explicit SONGMIX_FALLBACK value.
unless ($prefs->get('migratedSongMixFallback')) {
	my $moods = $prefs->get('profiles');
	if (ref $moods eq 'ARRAY' && grep { !($_->{fallback}) } @$moods) {
		$_->{fallback} ||= SONGMIX_FALLBACK for @$moods;
		$prefs->set('profiles', $moods);
	}
	$prefs->set('migratedSongMixFallback', 1);
}

# Per-player memory of tracks this plugin queued: url => { t => time queued,
# mood => mood id }. It lets mood changes remove them (guest requests are never
# touched), and lets repeat protection cover queued-but-unplayed tracks. Kept in
# a player preference ("queuedTracks") so it survives an LMS restart.
my %session;

# Called by LMS once at start-up. Wires the plugin into LMS: settings page,
# tag indexer, rescan notifications, DSTM provider, CLI commands and the
# My Apps menu (via the Slim::Plugin::OPMLBased base class).
sub initPlugin {
	my $class = shift;

	if (main::WEBUI) {
		require Plugins::JukeboxMoods::Settings;
		Plugins::JukeboxMoods::Settings->new;
	}

	Plugins::JukeboxMoods::TagIndex->init;
	Plugins::JukeboxMoods::Events->init;

	Slim::Control::Request::subscribe(\&_onRescanDone, [['rescan'], ['done']]);

	eval {
		require Slim::Plugin::DontStopTheMusic::Plugin;
		Slim::Plugin::DontStopTheMusic::Plugin->registerHandler(DSTM_TOKEN, \&dstmHandler);
	};
	$log->error("Could not register with Don't Stop The Music: $@") if $@;

	# players set up with the old provider name are moved to the new one
	_migrateDstmProvider($_) for Slim::Player::Client::clients();
	Slim::Control::Request::subscribe(sub { _migrateDstmProvider($_[0]->client) }, [['client'], ['new', 'reconnect']]);

	Slim::Control::Request::addDispatch(['jukeboxmoods', 'moods'],    [0, 1, 1, \&cliMoods]);
	Slim::Control::Request::addDispatch(['jukeboxmoods', 'activate'], [1, 0, 1, \&cliActivate]);
	Slim::Control::Request::addDispatch(['jukeboxmoods', 'count'],    [0, 1, 1, \&cliCount]);
	Slim::Control::Request::addDispatch(['jukeboxmoods', 'reindex'],  [0, 0, 0, \&cliReindex]);
	Slim::Control::Request::addDispatch(['jukeboxmoods', 'event'],    [1, 0, 1, \&cliEvent]);

	# The menu icon comes from <icon> in install.xml
	# (HTML/EN/plugins/JukeboxMoods/html/images/icon.png).
	$class->SUPER::initPlugin(
		feed   => \&handleFeed,
		tag    => 'jukeboxmoods',
		menu   => 'apps',
		is_app => 1,
		weight => 60,
	);
}

# Up to 0.1.6 our DSTM provider token was OLD_DSTM_TOKEN; switch any player
# still set to it over to DSTM_TOKEN so it keeps working after the upgrade.
sub _migrateDstmProvider {
	my $client = shift or return;
	eval {
		my $dstm = preferences('plugin.dontstopthemusic')->client($client->master);
		$dstm->set('provider', DSTM_TOKEN) if ($dstm->get('provider') || '') eq OLD_DSTM_TOKEN;
	};
}

# Called by LMS when the server stops or the plugin is disabled.
sub shutdownPlugin {
	Slim::Control::Request::unsubscribe(\&_onRescanDone);
	Plugins::JukeboxMoods::TagIndex->shutdown;
	Plugins::JukeboxMoods::Events->shutdown;
}

# Name shown for the My Apps menu entry (a strings.txt token).
sub getDisplayName { 'PLUGIN_JUKEBOXMOODS' }

# After every LMS library scan: drop cached mood results (track ids may have
# changed) and let the tag indexer pick up new or changed files.
sub _onRescanDone {
	Plugins::JukeboxMoods::Selector->libraryChanged;
	Plugins::JukeboxMoods::TagIndex->start(0);
}

# ---------------------------------------------------------------- profiles

# All moods, as stored in the 'profiles' preference (see sanitiseProfile).
sub profiles {
	my $p = $prefs->get('profiles');
	return ref $p eq 'ARRAY' ? $p : [];
}

# Look up a mood by its stable id. Returns undef if not found.
sub profileById {
	my $id = shift;
	return unless defined $id && length $id;
	for my $p (@{ profiles() }) {
		return $p if $p->{id} eq $id;
	}
	return;
}

# Look up a mood by id or, failing that, by name (case-insensitive). Used by the CLI.
sub findProfile {
	my $key = shift;
	return unless defined $key && length $key;
	return profileById($key) || (grep { lc($_->{name}) eq lc($key) } @{ profiles() })[0];
}

# The mood a player is currently using. Stored per player against the sync
# group master, so synced players share one mood. Falls back to the first mood.
sub activeProfile {
	my $client = shift or return;
	$client = $client->master;
	return profileById($prefs->client($client)->get('activeMood')) || profiles()->[0];
}

# Make a mood the player's active mood (the one top-ups start from). Fallbacks
# change only the active mood; the mood the user picked is kept separately.
sub setActive {
	my ($client, $profile) = @_;
	$prefs->client($client->master)->set('activeMood', $profile->{id});
}

# The mood the user last picked for this player (in My Apps or via the CLI).
# Fallbacks never change it; CHOSEN_FALLBACK returns to it.
sub chosenProfile {
	my $client = shift or return;
	$client = $client->master;
	return profileById($prefs->client($client)->get('chosenMood')) || activeProfile($client);
}

# The user picked a mood: it becomes both the chosen and the active mood.
sub setChosen {
	my ($client, $profile) = @_;
	$prefs->client($client->master)->set('chosenMood', $profile->{id});
	setActive($client, $profile);
}

# ---------------------------------------------------------------- picking

# Core selection routine: pick up to $count track URLs for a player.
#
# Starts with the active mood (or $opts{profile}) and, if that mood has
# nothing left, follows its fallback chain. A mood's fallback can be:
#   * another mood's id  -> try that mood next (it becomes the active mood)
#   * CHOSEN_FALLBACK    -> "Don't Stop the Music": go back to the mood the
#                           user picked; if that has nothing new either,
#                           replay from it (repeats allowed), then from the
#                           other moods tried, so the music never stops
#   * REPEAT_FALLBACK    -> "Restart Current Mood": replay this mood, repeats allowed
#   * SONGMIX_FALLBACK   -> "Song Mix": random tracks from the whole library
#   * STOP_FALLBACK      -> "Do Nothing": add nothing; playback ends with the queue
# Options:
#   profile     => start from this mood instead of the active one
#   ignoreQueue => don't exclude tracks already in the playlist (used when
#                  the queue is about to be cleared)
#   dstm        => called from a DSTM top-up (logs a warning when empty)
# Returns an array ref of track URLs (possibly empty).
sub pickForClient {
	my ($client, $count, %opts) = @_;
	$client = $client->master;

	# an event that ended with "Stop" asks for nothing more until a mood is picked
	if ($opts{dstm} && $prefs->client($client)->get('stopAdding')) {
		$log->info('Not adding tracks for ' . $client->name . ': the event ended with "stop"');
		return [];
	}

	my $start = $opts{profile} || activeProfile($client) or return [];

	# LMS never adds a track that is already anywhere in the playlist (played
	# or still to come). Exclude the whole playlist; otherwise LMS would discard
	# our picks and switch to a Song Mix before any fallback mood could run.
	my %exclude = $opts{ignoreQueue} ? () : %{ _playlistUrls($client) };
	%exclude = (%exclude, %{ _recentUrls($client) }) if $prefs->get('repeatProtect');

	my (%visited, @tried, @diag);
	my $profile = $start;

	# normal pick from one mood: respects repeat protection and the playlist
	my $tryMood = sub {
		my $mood = shift;
		$visited{ $mood->{id} } = 1;
		push @tried, $mood;
		my %d;
		my $urls = Plugins::JukeboxMoods::Selector->pick($mood, $count, { exclude => { %exclude }, diag => \%d });
		push @diag, sprintf("'%s': %d match, %d blocked by repeat protection, %d already in the playlist",
			$mood->{name}, $d{matched} || 0, $d{blocked} || 0, $d{excluded} || 0);
		return $urls;
	};

	# replay from one mood: repeats allowed (see _repeatFromMood)
	my $replayMood = sub {
		my $mood = shift;
		my $urls = _repeatFromMood($client, $mood, $count, $opts{ignoreQueue});
		push @diag, "'$mood->{name}' with repeats: " . scalar(@$urls) . ' track(s)';
		return $urls;
	};

	while ($profile && !$visited{ $profile->{id} }) {
		my $urls = $tryMood->($profile);
		return _useTracks($client, $start, $profile, $urls, \@diag) if @$urls;

		my $fallback = $profile->{fallback} || '';
		$log->info("Mood '$profile->{name}' has run dry");

		if ($fallback eq REPEAT_FALLBACK) {
			$urls = $replayMood->($profile);
			return _useTracks($client, $start, $profile, $urls, \@diag) if @$urls;
			last;
		}

		if ($fallback eq CHOSEN_FALLBACK) {
			my $chosen = chosenProfile($client);

			# first, anything new in the picked mood
			if ($chosen && !$visited{ $chosen->{id} }) {
				$urls = $tryMood->($chosen);
				return _useTracks($client, $start, $chosen, $urls, \@diag) if @$urls;
			}

			# then replay: the picked mood first, then the other moods tried
			my %seen;
			for my $mood (grep { $_ && !$seen{ $_->{id} }++ } ($chosen, @tried)) {
				$urls = $replayMood->($mood);
				return _useTracks($client, $start, $mood, $urls, \@diag) if @$urls;
			}
			last;
		}

		if ($fallback eq SONGMIX_FALLBACK || $fallback eq '') {
			$urls = _songMix($client, $count, \%exclude, $opts{ignoreQueue});
			push @diag, 'Song Mix: ' . scalar(@$urls) . ' track(s)';
			if (@$urls) {
				$log->info('Picked ' . scalar(@$urls) . ' Song Mix track(s). ' . join('; ', @diag));
				_remember($client, $urls, 'songmix');
				return $urls;
			}
			last;
		}

		if ($fallback eq STOP_FALLBACK) {
			push @diag, 'fallback is Do Nothing';
			last;
		}

		$profile = profileById($fallback);
	}

	my $msg = 'No tracks available for ' . $client->name . '. ' . join('; ', @diag);
	$opts{dstm} ? $log->warn($msg) : $log->info($msg);
	return [];
}

# "Song Mix" fallback: random tracks from the whole library. Respects repeat
# protection where possible, then relaxes it rather than return nothing.
sub _songMix {
	my ($client, $count, $exclude, $ignoreQueue) = @_;
	my $library = { id => 'songmix', name => 'Song Mix', match => 'all', rules => [], exclude => [] };
	my $urls = Plugins::JukeboxMoods::Selector->pick($library, $count, { exclude => { %$exclude } });
	return $urls if @$urls;
	my %inPlaylist = $ignoreQueue ? () : %{ _playlistUrls($client) };
	return Plugins::JukeboxMoods::Selector->pick($library, $count, { exclude => \%inPlaylist, ignoreRepeat => 1 });
}

# Hand out picked tracks: if they came from a different mood than the one we
# started from, make that mood active and (optionally) announce the change.
sub _useTracks {
	my ($client, $start, $mood, $urls, $diag) = @_;
	if ($mood->{id} ne $start->{id}) {
		setActive($client, $mood);
		_announce($client, $mood) if $prefs->get('announceFallback');
		$log->info("Fell back to mood '$mood->{name}'");
	}
	$log->info('Picked ' . scalar(@$urls) . ' track(s). ' . join('; ', @$diag));
	_remember($client, $urls, $mood->{id});
	return $urls;
}

# "Keep playing this mood": ignore repeat protection and reuse tracks already
# played in this playlist. LMS refuses tracks that are still in the playlist,
# so earlier (already played) copies of the chosen tracks are removed first.
sub _repeatFromMood {
	my ($client, $profile, $count, $ignoreQueue) = @_;
	my $upcoming = $ignoreQueue ? {} : _upcomingUrls($client);
	my $urls = Plugins::JukeboxMoods::Selector->pick($profile, $count, { exclude => { %$upcoming }, ignoreRepeat => 1 });
	return $urls if $ignoreQueue || !@$urls;

	my %chosen = map { $_ => 1 } grep { !$upcoming->{$_} } @$urls;
	my ($list, $current) = _playlistState($client);
	_deleteIndexes($client, grep { my $u = _urlOf($list->[$_]); defined $u && $chosen{$u} } (0 .. $current - 1));
	return $urls;
}

# DSTM provider callback, registered in initPlugin. LMS calls this with the
# player and a callback whenever the queue is about to run out, and adds
# whatever URLs we pass to the callback.
sub dstmHandler {
	my ($client, $cb) = @_;
	my $master = $client->master;

	# Note: LMS asks whenever fewer than two tracks are lined up after the one
	# it is currently loading. If we answer with an empty list, LMS falls back
	# to a Song Mix (Random Play), so we only return nothing when no mood,
	# fallback or relaxed retry can supply a single track.
	my $urls = pickForClient($master, $prefs->get('tracksPerTopup') || 2, dstm => 1);

	$log->info('Top-up for ' . $master->name . ': ' . scalar(@$urls) . ' track(s)') if @$urls;
	$cb->($client, $urls);
}

# mode: queue   = make active, takes effect at the next top-up
#       replace = remove queued mood tracks, add tracks from the new mood
#       play    = clear the queue and start playing the new mood
sub switchMood {
	my ($client, $profile, $mode) = @_;
	$client = $client->master;
	$mode ||= 'queue';

	setChosen($client, $profile);
	$prefs->client($client)->set('stopAdding', 0);   # picking a mood always resumes adding tracks
	my $count = $prefs->get('tracksPerTopup') || 2;

	if ($mode eq 'play') {
		my $urls = pickForClient($client, max(3, $count), profile => $profile, ignoreQueue => 1);
		return 0 unless @$urls;
		$client->execute(['playlist', 'play', shift @$urls]);
		$client->execute(['playlist', 'add', $_]) for @$urls;
		return 1;
	}

	if ($mode eq 'replace') {
		_removeQueuedMoodTracks($client);
		my $urls = pickForClient($client, $count, profile => $profile);
		$client->execute(['playlist', 'add', $_]) for @$urls;
		_placeNext($client, $urls);
		return @$urls ? 1 : 0;
	}

	return 1;
}

# Playlist entries can be track objects or plain URLs; return the URL either way.
sub _urlOf {
	my $item = shift;
	return unless defined $item;
	return $item->url if blessed($item) && $item->can('url');
	return ref $item ? undef : $item;
}

# The player's playlist (array ref) and the index of the song now playing.
sub _playlistState {
	my $client = shift;
	my $list    = eval { Slim::Player::Playlist::playList($client) } || [];
	my $current = eval { Slim::Player::Source::playingSongIndex($client) } || 0;
	return ($list, $current);
}

# Set (hash ref) of every URL in the playlist, played or upcoming.
# True if the song now playing was queued by this plugin (not a guest request).
sub currentIsMoodTrack {
	my $client = shift->master;
	my ($list, $current) = _playlistState($client);
	my $url = _urlOf($list->[$current]);
	return defined $url && _queued($client)->{$url} ? 1 : 0;
}

sub _playlistUrls {
	my $client = shift;
	my ($list) = _playlistState($client);
	my %urls;
	for my $item (@$list) {
		my $url = _urlOf($item);
		$urls{$url} = 1 if defined $url;
	}
	return \%urls;
}

# Set of URLs from the song now playing to the end of the playlist.
sub _upcomingUrls {
	my $client = shift;
	my ($list, $current) = _playlistState($client);
	my %urls;
	for my $i ($current .. $#$list) {
		my $url = _urlOf($list->[$i]);
		$urls{$url} = 1 if defined $url;
	}
	return \%urls;
}

# Set of URLs this plugin queued for the player within the repeat window.
sub _recentUrls {
	my $client = shift;
	my $since  = time() - ($prefs->get('repeatMinutes') || 60) * 60;
	my $queued = _queued($client);
	return { map { $_ => 1 } grep { _queuedAt($queued->{$_}) >= $since } keys %$queued };
}

# This player's memory of tracks the plugin queued (loaded from its preference
# the first time it is needed after a restart).
sub _queued {
	my $client = shift->master;
	my $id = $client->id;
	unless ($session{$id}{added}) {
		my $saved = $prefs->client($client)->get('queuedTracks');
		$session{$id}{added} = ref $saved eq 'HASH' ? { %$saved } : {};
	}
	return $session{$id}{added};
}

sub _saveQueued {
	my $client = shift->master;
	$prefs->client($client)->set('queuedTracks', { %{ _queued($client) } });
}

# When a remembered track was queued.
sub _queuedAt { my $v = shift; return ref $v ? ($v->{t} || 0) : ($v || 0) }

# Record URLs this plugin has just queued for the player, and from which mood.
sub _remember {
	my ($client, $urls, $moodId) = @_;
	my $now    = time();
	my $queued = _queued($client);
	$queued->{$_} = { t => $now, mood => $moodId || '' } for @$urls;

	# keep memory bounded: forget entries older than the protection window (min 12h)
	my $keep = max(12 * 60, $prefs->get('repeatMinutes') || 60) * 60;
	delete $queued->{$_} for grep { _queuedAt($queued->{$_}) < $now - $keep } keys %$queued;
	_saveQueued($client);
}

# Remove playlist entries by position. LMS's "playlist delete" takes an index
# (not a URL); deleting from the highest index down keeps the others valid.
sub _deleteIndexes {
	my ($client, @idx) = @_;
	my %seen;
	$client->execute(['playlist', 'delete', $_]) for sort { $b <=> $a } grep { !$seen{$_}++ } @idx;
}

# Remove upcoming tracks that this plugin queued, leaving the user's own
# tracks alone. Used when the mood changes ("Switch now" and event slots).
sub _removeQueuedMoodTracks {
	my $client = shift;
	my $queued = _queued($client);

	my ($list, $current) = _playlistState($client);
	my $currentUrl = _urlOf($list->[$current]);

	my (%remove, @indexes, $guests);
	for my $i ($current + 1 .. $#$list) {
		my $url = _urlOf($list->[$i]);
		next unless defined $url;
		if ($queued->{$url} && !(defined $currentUrl && $url eq $currentUrl)) { $remove{$url} = 1; push @indexes, $i }
		else { $guests++ }
	}

	_deleteIndexes($client, @indexes);

	# forget only what really left the queue: a track LMS kept (e.g. one it was
	# already loading) stays known as a mood track, so the new mood goes before it
	my ($after) = _playlistState($client);
	my %still = map { (_urlOf($_) // '') => 1 } @$after;
	my $removed = 0;
	for my $url (keys %remove) {
		next if $still{$url};
		delete $queued->{$url};
		$removed++;
	}
	_saveQueued($client);
	$log->info(sprintf('Mood change on %s: removed %d of %d queued mood track(s), kept %d guest request(s)',
		$client->name, $removed, scalar(keys %remove), $guests || 0));
}

# Move freshly added mood tracks (appended at the end of the playlist) so they
# play straight after the current song and any guest requests behind it -
# ahead of any old mood track LMS kept (for example one it had already started
# loading for gapless playback).
sub _placeNext {
	my ($client, $urls) = @_;
	return unless @$urls;
	my %new = map { $_ => 1 } @$urls;
	my $queued = _queued($client);

	my ($list, $current) = _playlistState($client);
	my $target = $current;   # the last guest request after the current song, if any
	for my $i ($current + 1 .. $#$list) {
		my $url = _urlOf($list->[$i]);
		next unless defined $url;
		$target = $i if !$new{$url} && !$queued->{$url};
	}

	my $k = 0;
	for my $url (@$urls) {
		($list, $current) = _playlistState($client);
		my ($from) = grep { (_urlOf($list->[$_]) // '') eq $url } reverse($current + 1 .. $#$list);
		my $to = $target + 1 + $k++;
		$client->execute(['playlist', 'move', $from, $to]) if defined $from && $from != $to;
	}

	# Earlier mood tracks LMS kept are now behind the new mood, so it is no
	# longer loading them: try removing them once more.
	($list, $current) = _playlistState($client);
	my @leftIdx = grep { my $u = _urlOf($list->[$_]); defined $u && !$new{$u} && $queued->{$u} } ($current + 1 .. $#$list);
	my @left    = map { _urlOf($list->[$_]) } @leftIdx;
	if (@left) {
		_deleteIndexes($client, @leftIdx);
		($list) = _playlistState($client);
		my %still = map { (_urlOf($_) // '') => 1 } @$list;
		for my $url (@left) {
			if ($still{$url}) { $log->warn('Mood change on ' . $client->name . ": LMS kept an earlier mood track: $url") }
			else              { delete $queued->{$url} }
		}
		_saveQueued($client);
	}
}

# Briefly show 'Mood ran dry, switched to X' on the player (and on Jive controllers).
sub _announce {
	my ($client, $profile) = @_;
	my $msg = sprintf(cstring($client, 'PLUGIN_JUKEBOXMOODS_FELLBACK'), $profile->{name});
	eval {
		$client->showBriefly({
			line => [ cstring($client, 'PLUGIN_JUKEBOXMOODS'), $msg ],
			jive => { type => 'popupplay', text => [ $msg ] },
		}, { duration => 4 });
	};
}

# ---------------------------------------------------------------- menu

# Builds the My Apps > Jukebox Moods menu (an OPML-style feed rendered by the
# web UI, Material Skin and controller apps). Top level: active mood, an
# optional DSTM tip, then one entry per mood with three switching actions.
sub handleFeed {
	my ($client, $cb, $args) = @_;

	unless ($client) {
		return $cb->({ items => [{ name => cstring($client, 'PLUGIN_JUKEBOXMOODS_NO_PLAYER'), type => 'text' }] });
	}

	my $profiles = profiles();
	unless (@$profiles) {
		return $cb->({ items => [{ name => cstring($client, 'PLUGIN_JUKEBOXMOODS_NO_MOODS'), type => 'text' }] });
	}

	my @items;
	my ($event, $slot, $state) = Plugins::JukeboxMoods::Events::running($client);

	if ($event && $slot >= 0 && $slot < @{ $event->{slots} }) {
		# status of the running event, with quick controls
		my $mood = profileById($event->{slots}[$slot]{mood});
		my $end  = Plugins::JukeboxMoods::Events::slotEnd($event, $state->{startedAt}, $slot);
		push @items, { type => 'text', name => sprintf(cstring($client, 'PLUGIN_JUKEBOXMOODS_EVENT_STATUS'),
			$event->{name}, $mood ? $mood->{name} : '?',
			$end ? sprintf(cstring($client, 'PLUGIN_JUKEBOXMOODS_UNTIL'), Plugins::JukeboxMoods::Events::clock($end)) : cstring($client, 'PLUGIN_JUKEBOXMOODS_UNTIL_STOPPED')) };
		push @items, _eventAction($client, $event, 'next', 'PLUGIN_JUKEBOXMOODS_NEXT_SLOT');
		push @items, _eventAction($client, $event, 'stop', 'PLUGIN_JUKEBOXMOODS_STOP_EVENT');
	}
	else {
		my $active = activeProfile($client);
		my $chosen = chosenProfile($client);
		my $status = sprintf(cstring($client, 'PLUGIN_JUKEBOXMOODS_ACTIVE_IS'), $active ? $active->{name} : '-');
		# after a fallback, also show the mood the user picked
		$status .= ' ' . sprintf(cstring($client, 'PLUGIN_JUKEBOXMOODS_PICKED'), $chosen->{name})
			if $active && $chosen && $active->{id} ne $chosen->{id};
		push @items, { name => $status, type => 'text' };
		push @items, { name => cstring($client, 'PLUGIN_JUKEBOXMOODS_STOPPED_ADDING'), type => 'text' }
			if $prefs->client($client->master)->get('stopAdding');
	}

	my $provider = eval { preferences('plugin.dontstopthemusic')->client($client->master)->get('provider') };
	if (defined $provider && $provider ne DSTM_TOKEN) {
		push @items, { name => cstring($client, 'PLUGIN_JUKEBOXMOODS_DSTM_TIP'), type => 'text' };
	}

	# events: one entry each, opening Start now / Cancel and the slot list
	for my $e (@{ Plugins::JukeboxMoods::Events::events() }) {
		next unless @{ $e->{slots} || [] };
		my $isRunning = $event && $event->{id} eq $e->{id};
		my $pending   = Plugins::JukeboxMoods::Events::isPending($e);
		my $label = sprintf(cstring($client, 'PLUGIN_JUKEBOXMOODS_EVENT_ITEM'), $e->{name});
		$label .= ' (' . _when($e) . ')' if $pending;
		$label .= ' ' . cstring($client, 'PLUGIN_JUKEBOXMOODS_ACTIVE_MARK') if $isRunning;

		my @sub = $isRunning
			? (_eventAction($client, $e, 'next', 'PLUGIN_JUKEBOXMOODS_NEXT_SLOT'), _eventAction($client, $e, 'stop', 'PLUGIN_JUKEBOXMOODS_STOP_EVENT'))
			: (_eventAction($client, $e, 'start', 'PLUGIN_JUKEBOXMOODS_START_EVENT'));
		push @sub, _eventAction($client, $e, 'cancel', 'PLUGIN_JUKEBOXMOODS_CANCEL_EVENT') if $pending;
		my $n = 0;
		for my $s (@{ $e->{slots} }) {
			my $m = profileById($s->{mood});
			push @sub, { type => 'text', name => sprintf('%d. %s - %s', ++$n, $m ? $m->{name} : '?',
				$s->{minutes} ? "$s->{minutes} min" : cstring($client, 'PLUGIN_JUKEBOXMOODS_UNTIL_STOPPED')) };
		}
		push @items, { name => $label, type => 'link', items => \@sub };
	}

	# moods, with the three switching actions
	my $active = activeProfile($client);
	for my $p (@$profiles) {
		my $isActive = $active && $active->{id} eq $p->{id};
		push @items, {
			name  => $isActive ? $p->{name} . ' ' . cstring($client, 'PLUGIN_JUKEBOXMOODS_ACTIVE_MARK') : $p->{name},
			type  => 'link',
			items => [
				_action($client, $p, 'replace', 'PLUGIN_JUKEBOXMOODS_SWITCH_NOW'),
				_action($client, $p, 'queue',   'PLUGIN_JUKEBOXMOODS_SWITCH_NEXT'),
				_action($client, $p, 'play',    'PLUGIN_JUKEBOXMOODS_PLAY_NOW'),
			],
		};
	}

	$cb->({ items => \@items });
}

# Short start description for a scheduled event, e.g. "Sat 14:00".
sub _when {
	my $e = shift;
	my $t = Plugins::JukeboxMoods::Events::parseStart($e->{startAt}) or return '';
	return POSIX::strftime('%a %d %b %H:%M', localtime($t));
}

# One event action item for the menu (start, next, stop, cancel).
sub _eventAction {
	my ($client, $event, $do, $token) = @_;
	return {
		name        => cstring($client, $token),
		type        => 'link',
		url         => \&_eventMenuAction,
		passthrough => [{ id => $event->{id}, do => $do }],
		nextWindow  => $do eq 'start' ? 'nowPlaying' : 'grandparent',
	};
}

sub _eventMenuAction {
	my ($client, $cb, $params, $args) = @_;
	my $event = Plugins::JukeboxMoods::Events::eventById($args->{id});
	my $ok = $event && runEventCommand($client, $event, $args->{do});
	$cb->({ items => [{ name => cstring($client, $ok ? 'PLUGIN_JUKEBOXMOODS_DONE' : 'PLUGIN_JUKEBOXMOODS_NOTHING_TO_DO'), type => 'text', showBriefly => 1 }] });
}

# Carry out an event command for the menu and CLI: start | next | stop | cancel.
# A manual event without a fixed player runs on the player it is started from;
# otherwise on its configured player when that is connected.
sub runEventCommand {
	my ($client, $event, $do) = @_;
	my $target = ($event->{player} && Slim::Player::Client::getClient($event->{player})) || $client;
	return Plugins::JukeboxMoods::Events->start($target, $event) if $do eq 'start';
	return Plugins::JukeboxMoods::Events->nextSlot($client)      if $do eq 'next';
	return Plugins::JukeboxMoods::Events->stop($client)          if $do eq 'stop';
	return Plugins::JukeboxMoods::Events->cancel($event)         if $do eq 'cancel';
	return 0;
}

# One switching action item for the menu (see switchMood for the modes).
sub _action {
	my ($client, $profile, $mode, $token) = @_;
	return {
		name        => cstring($client, $token),
		type        => 'link',
		url         => \&_menuAction,
		passthrough => [{ id => $profile->{id}, mode => $mode }],
		nextWindow  => $mode eq 'play' ? 'nowPlaying' : 'grandparent',
	};
}

# Runs when a menu action is chosen; switches the mood and reports the result.
sub _menuAction {
	my ($client, $cb, $params, $args) = @_;
	my $profile = profileById($args->{id});
	my $ok = $profile && switchMood($client, $profile, $args->{mode});
	my $msg = $ok
		? sprintf(cstring($client, 'PLUGIN_JUKEBOXMOODS_SWITCHED'), $profile->{name})
		: cstring($client, 'PLUGIN_JUKEBOXMOODS_NOTHING');
	$cb->({ items => [{ name => $msg, type => 'text', showBriefly => 1 }] });
}

# ---------------------------------------------------------------- CLI

# <player> jukeboxmoods moods
sub cliMoods {
	my $request = shift;
	my $client  = $request->client;
	my $active  = $client ? activeProfile($client) : undef;
	my $i = 0;
	for my $p (@{ profiles() }) {
		$request->addResultLoop('moods_loop', $i, 'id',     $p->{id});
		$request->addResultLoop('moods_loop', $i, 'name',   $p->{name});
		$request->addResultLoop('moods_loop', $i, 'active', ($active && $active->{id} eq $p->{id}) ? 1 : 0);
		$i++;
	}
	$request->addResult('count', $i);
	$request->setStatusDone;
}

# <player> jukeboxmoods activate mood:<name or id> [mode:queue|replace|play]
sub cliActivate {
	my $request = shift;
	my $client  = $request->client;
	my $profile = findProfile($request->getParam('mood'));
	my $mode    = $request->getParam('mode') || 'queue';

	if (!$client || !$profile || $mode !~ /^(?:queue|replace|play)$/) {
		$request->setStatusBadParams;
		return;
	}

	$request->addResult('ok', switchMood($client, $profile, $mode) ? 1 : 0);
	$request->setStatusDone;
}

# jukeboxmoods count profile:<json>   (used by the settings page)
sub cliCount {
	my $request = shift;
	my $data = decodeJson($request->getParam('profile'));
	unless (ref $data eq 'HASH') {
		$request->setStatusBadParams;
		return;
	}
	my ($total, $available) = Plugins::JukeboxMoods::Selector->count(sanitiseProfile($data));
	$request->addResult('count', $total);
	$request->addResult('available', $available);
	$request->addResult('indexing', Plugins::JukeboxMoods::TagIndex->status->{state} eq 'indexing' ? 1 : 0);
	$request->setStatusDone;
}

# jukeboxmoods reindex  - re-read every file's tags (forced index rebuild).
# <player> jukeboxmoods event cmd:start|next|stop|cancel [event:<name or id>]
# (start and cancel need event:, next and stop act on the player's running event)
sub cliEvent {
	my $request = shift;
	my $client  = $request->client;
	my $do      = $request->getParam('cmd') || '';
	my $event   = Plugins::JukeboxMoods::Events::findEvent($request->getParam('event'));
	($event) = Plugins::JukeboxMoods::Events::running($client) if !$event && $client && $do =~ /^(?:next|stop)$/;

	if (!$client || !$event || $do !~ /^(?:start|next|stop|cancel)$/) {
		$request->setStatusBadParams;
		return;
	}
	$request->addResult('ok', runEventCommand($client, $event, $do) ? 1 : 0);
	$request->setStatusDone;
}

sub cliReindex {
	my $request = shift;
	Plugins::JukeboxMoods::TagIndex->start(1);
	$request->setStatusDone;
}

# ---------------------------------------------------------------- validation

# Decode JSON from the settings page or CLI. Web form values may arrive as
# decoded characters or as UTF-8 bytes, so both are tried.
sub decodeJson {
	my $text = shift;
	return unless defined $text && length $text;
	my $data = utf8::is_utf8($text)
		? eval { from_json($text) }
		: eval { JSON::XS::decode_json($text) };
	$data = eval { from_json($text) } unless ref $data;
	return $data;
}

# Validate and normalise one mood coming from the settings page or CLI.
# Never trust browser input: unknown fields and operators are dropped, sizes
# are capped, and a stable id is generated when missing. Stored shape:
#   { id, name, match => 'all'|'any', rules => [...], exclude => [...], fallback }
# where each rule is { field, op, value [, value2] }.
sub sanitiseProfile {
	my $p = shift;
	my $name = _str($p->{name}, 80);
	my $fb = defined $p->{fallback} ? $p->{fallback} : '';
	my $fallback = $SPECIAL_FALLBACK{$fb} ? $fb : (_validId($fb) || CHOSEN_FALLBACK);
	$name = 'Untitled mood' unless length $name;

	return {
		id       => _validId($p->{id}) || _newId(),
		name     => $name,
		match    => (defined $p->{match} && $p->{match} eq 'any') ? 'any' : 'all',
		fallback => $fallback,
		rules    => _cleanRules($p->{rules}),
		exclude  => _cleanRules($p->{exclude}),
	};
}

# Validate a list of rules against the field and operator catalogue in Selector.pm.
sub _cleanRules {
	my $rules = shift;
	return [] unless ref $rules eq 'ARRAY';
	my @clean;
	for my $r (@$rules) {
		next unless ref $r eq 'HASH';
		my $info = Plugins::JukeboxMoods::Selector->fieldInfo($r->{field}) or next;
		next unless Plugins::JukeboxMoods::Selector->validOp($info->{type}, $r->{op});
		my %rule = (field => $info->{name}, op => $r->{op}, value => _str($r->{value}, 200));
		$rule{value2} = _str($r->{value2}, 200) if $r->{op} =~ /between/;
		push @clean, \%rule;
		last if @clean >= 50;
	}
	return \@clean;
}

# Mood ids: 1-40 characters of letters, digits, '_' and '-'.
sub _validId {
	my $id = shift;
	return (defined $id && !ref $id && $id =~ /^[A-Za-z0-9_-]{1,40}$/) ? $id : undef;
}

# Generate a new random mood id.
sub _newId {
	my @chars = ('a' .. 'z', 0 .. 9);
	return 'm' . join('', map { $chars[ rand @chars ] } 1 .. 10);
}

# Trim a value to a plain string of at most $len characters.
sub _str {
	my ($v, $len) = @_;
	$v = '' unless defined $v && !ref $v;
	$v =~ s/^\s+|\s+$//g;
	return substr($v, 0, $len);
}

1;

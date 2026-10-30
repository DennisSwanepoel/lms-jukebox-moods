package Plugins::JukeboxMoods::Selector;

# =============================================================================
# Jukebox Moods - rule engine
# Part of Jukebox Moods. Licensed under the GNU GPL v2 or later (see LICENSE).
#
# Turns a mood's rules into a set of tracks and picks from it.
#
# How it works:
#   1. Every rule becomes one SQL query against the LMS library database
#      (or, for file tags, against TagIndex's own database). Each query
#      returns a set of track "urlmd5" values - the MD5 of the track URL,
#      which LMS stores and which we use as a stable track key.
#   2. Negative operators ("is not", "does not contain", ...) are computed
#      as "whole library minus the positive set", which is correct for
#      multi-valued fields such as genre and artist.
#   3. Sets are combined in Perl: intersection for "all", union for "any";
#      exclusion rules are subtracted.
#   4. The resulting candidate list is cached for CACHE_TTL seconds.
#   5. pick() removes tracks blocked by repeat protection or already in the
#      playlist, shuffles, and returns the requested number of URLs.
#
# The LMS library database is only ever read, never written.
#
# To add a library field: add it to %FIELDS and @FIELD_ORDER below; the
# settings editor and validation pick it up automatically.
# =============================================================================

use strict;
use warnings;

use Data::Dumper ();
use List::Util qw(shuffle);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::JukeboxMoods::TagIndex;

use constant CACHE_TTL => 600;   # seconds; ratings/play counts change over time

my $prefs = preferences('plugin.jukeboxmoods');
my $log;
sub _log { $log ||= logger('plugin.jukeboxmoods') }

my $libraryGeneration = 0;
my %cache;

my $CONTRIB = 'tracks t JOIN contributor_track ct ON ct.track = t.id JOIN contributors c ON c.id = ct.contributor';
my $PERSIST = 'tracks t LEFT JOIN tracks_persistent tp ON tp.urlmd5 = t.urlmd5';

my @FIELD_ORDER = qw(
	artist albumartist trackartist composer conductor band album title genre year comment
	rating playcount lastplayed added bpm duration format bitrate samplerate
);

my %FIELDS = (
	artist      => { label => 'Artist (any artist role)', type => 'text', from => $CONTRIB, where => 'ct.role IN (1,5,6)', col => 'c.namesearch', normalise => 1 },
	albumartist => { label => 'Album artist (tagged)',    type => 'text', from => $CONTRIB, where => 'ct.role = 5', col => 'c.namesearch', normalise => 1 },
	trackartist => { label => 'Track artist',             type => 'text', from => $CONTRIB, where => 'ct.role = 6', col => 'c.namesearch', normalise => 1 },
	composer    => { label => 'Composer',                 type => 'text', from => $CONTRIB, where => 'ct.role = 2', col => 'c.namesearch', normalise => 1 },
	conductor   => { label => 'Conductor',                type => 'text', from => $CONTRIB, where => 'ct.role = 3', col => 'c.namesearch', normalise => 1 },
	band        => { label => 'Band / orchestra',         type => 'text', from => $CONTRIB, where => 'ct.role = 4', col => 'c.namesearch', normalise => 1 },
	album       => { label => 'Album',                    type => 'text', from => 'tracks t JOIN albums a ON a.id = t.album', col => 'a.titlesearch', normalise => 1 },
	title       => { label => 'Track title',              type => 'text', from => 'tracks t', col => 't.titlesearch', normalise => 1 },
	genre       => { label => 'Genre',                    type => 'text', from => 'tracks t JOIN genre_track gt ON gt.track = t.id JOIN genres g ON g.id = gt.genre', col => 'g.namesearch', normalise => 1 },
	comment     => { label => 'Comment',                  type => 'text', from => 'tracks t JOIN comments cm ON cm.track = t.id', col => 'cm.value' },
	format      => { label => 'File format (flc, mp3, alc, aac ...)', type => 'text', from => 'tracks t', col => 't.content_type' },
	year        => { label => 'Year',                     type => 'number', from => 'tracks t', col => 't.year' },
	rating      => { label => 'Rating (stars 0-5)',       type => 'number', from => $PERSIST, col => 'COALESCE(tp.rating, 0) / 20.0' },
	playcount   => { label => 'Play count',               type => 'number', from => $PERSIST, col => 'COALESCE(tp.playCount, 0)' },
	lastplayed  => { label => 'Last played (days ago, never = very large)', type => 'number', from => $PERSIST, col => 'COALESCE((%NOW% - tp.lastPlayed) / 86400.0, 999999)' },
	added       => { label => 'Added to library (days ago)', type => 'number', from => $PERSIST, col => '(%NOW% - COALESCE(tp.added, t.timestamp)) / 86400.0' },
	bpm         => { label => 'BPM',                      type => 'number', from => 'tracks t', col => 't.bpm' },
	duration    => { label => 'Duration (minutes)',       type => 'number', from => 'tracks t', col => 't.secs / 60.0' },
	bitrate     => { label => 'Bitrate (kbps)',           type => 'number', from => 'tracks t', col => 't.bitrate / 1000.0' },
	samplerate  => { label => 'Sample rate (Hz)',         type => 'number', from => 'tracks t', col => 't.samplerate' },
);

my %OPS = (
	text   => [qw(is isnot contains notcontains startswith isset notset)],
	number => [qw(eq ne gt gte lt lte between notbetween)],
	custom => [qw(is isnot contains notcontains startswith isset notset gt gte lt lte between notbetween)],
);

my %OP_LABELS = (
	is => 'is', isnot => 'is not', contains => 'contains', notcontains => 'does not contain',
	startswith => 'starts with', isset => 'has a value', notset => 'has no value',
	eq => '=', ne => 'is not', gt => '>', gte => '>=', lt => '<', lte => '<=',
	between => 'between', notbetween => 'not between',
);

my %NEGATED = (isnot => 'is', notcontains => 'contains', ne => 'eq', notset => 'isset', notbetween => 'between');
my %CMP     = (eq => '=', gt => '>', gte => '>=', lt => '<', lte => '<=');

# ---------------------------------------------------------------- metadata for UI and validation

# Describe a rule field: { name, type } where type is text, number or custom
# (a file tag, written as "custom:TAGNAME"). Returns undef for unknown fields.
sub fieldInfo {
	my ($class, $name) = @_;
	return unless defined $name && !ref $name;
	if ($name =~ /^custom:(.+)$/i) {
		my $tag = Plugins::JukeboxMoods::TagIndex::normaliseTag($1) or return;
		return { name => "custom:$tag", type => 'custom' };
	}
	return $FIELDS{$name} ? { name => $name, type => $FIELDS{$name}{type} } : undef;
}

# True if $op is allowed for fields of $type (see %OPS).
sub validOp {
	my ($class, $type, $op) = @_;
	return 0 unless defined $op && $OPS{$type};
	return scalar grep { $_ eq $op } @{ $OPS{$type} };
}

# Field catalogue for the settings editor: library fields, then any file tags passed in.
sub fieldList {
	my ($class, $tags) = @_;
	my @list = map { { name => $_, label => $FIELDS{$_}{label}, type => $FIELDS{$_}{type}, group => 'library' } } @FIELD_ORDER;
	push @list, { name => "custom:$_", label => $_, type => 'custom', group => 'custom' } for @{ $tags || [] };
	return \@list;
}

# Operator catalogue for the settings editor, grouped by field type.
sub operators {
	my %out;
	for my $type (keys %OPS) {
		$out{$type} = [ map { { op => $_, label => $OP_LABELS{$_} } } @{ $OPS{$type} } ];
	}
	return \%out;
}

# Called after an LMS rescan: invalidates every cached candidate list.
sub libraryChanged {
	$libraryGeneration++;
	%cache = ();
}

# ---------------------------------------------------------------- selection

# All tracks (as urlmd5 values) that a mood's rules allow, before repeat
# protection and playlist exclusions. Cached; pass $fresh to bypass the cache.
sub candidates {
	my ($class, $profile, $fresh) = @_;

	my $key = _cacheKey($profile);
	my $hit = $cache{$key};
	return $hit->{list} if !$fresh && $hit && $hit->{time} > time() - CACHE_TTL;

	my $universe = _set(_query('SELECT urlmd5 FROM tracks WHERE audio = 1 AND remote = 0'));
	my @rules = @{ $profile->{rules} || [] };
	my $result;

	if (!@rules) {
		$result = { %$universe };
	}
	elsif (($profile->{match} || 'all') eq 'any') {
		$result = {};
		for my $rule (@rules) {
			my $s = _ruleSet($rule, $universe);
			@$result{ keys %$s } = ();
		}
	}
	else {
		for my $rule (@rules) {
			my $s = _ruleSet($rule, $universe);
			$result = defined $result ? _set([ grep { exists $s->{$_} } keys %$result ]) : $s;
			last unless %$result;
		}
	}

	for my $rule (@{ $profile->{exclude} || [] }) {
		last unless %$result;
		my $s = _ruleSet($rule, $universe);
		delete @$result{ keys %$s };
	}

	my @list = grep { exists $universe->{$_} } keys %$result;

	%cache = () if keys %cache > 20;
	$cache{$key} = { time => time(), list => \@list };

	_log()->info(sprintf("Mood '%s': %d matching tracks", $profile->{name} || '?', scalar @list));
	return \@list;
}

# Pick up to $count track URLs from a mood at random.
# Options:
#   exclude      => { url => 1, ... }  URLs that must not be returned
#   ignoreRepeat => 1                  don't apply repeat protection
#   diag         => {}                 filled with matched/blocked/excluded
#                                      counts, used for log messages
sub pick {
	my ($class, $profile, $count, $opts) = @_;
	$opts ||= {};

	my $diag = $opts->{diag} || {};
	my $candidates = $class->candidates($profile);
	%$diag = (matched => scalar @$candidates, blocked => 0, excluded => 0);
	return [] unless @$candidates;

	my $blocked  = $opts->{ignoreRepeat} ? undef : _blockedSet();
	my @eligible = $blocked ? grep { !exists $blocked->{$_} } @$candidates : @$candidates;
	$diag->{blocked} = @$candidates - @eligible;
	return [] unless @eligible;

	my %skip = %{ $opts->{exclude} || {} };
	my @pool = shuffle @eligible;
	my @picked;

	while (@pool && @picked < $count) {
		my @chunk = splice(@pool, 0, 50);
		my $urls  = _urlsFor(\@chunk);
		for my $md5 (@chunk) {
			my $url = $urls->{$md5};
			next unless defined $url;
			if ($skip{$url}++) { $diag->{excluded}++; next; }
			push @picked, $url;
			last if @picked >= $count;
		}
	}

	return \@picked;
}

# For the settings page: (tracks matching the mood, tracks available right now).
sub count {
	my ($class, $profile) = @_;
	my $list    = $class->candidates($profile, 1);
	my $blocked = _blockedSet();
	my $available = $blocked ? scalar(grep { !exists $blocked->{$_} } @$list) : scalar(@$list);
	return (scalar(@$list), $available);
}

# ---------------------------------------------------------------- internals

# Set of urlmd5 values matched by one rule (handles negative operators).
sub _ruleSet {
	my ($rule, $universe) = @_;
	my $op       = $rule->{op};
	my $positive = $NEGATED{$op} || $op;
	my $set      = _positiveSet($rule->{field}, $positive, $rule->{value}, $rule->{value2});
	return $set unless $NEGATED{$op};
	# negation = everything in the library that the positive rule did not match
	# (correct for multi-valued fields such as genre and artist)
	return _set([ grep { !exists $set->{$_} } keys %$universe ]);
}

# Run the SQL for one rule's positive operator and return the matching set.
sub _positiveSet {
	my ($field, $op, $v1, $v2) = @_;

	if ($field =~ /^custom:(.+)$/) {
		return _set(Plugins::JukeboxMoods::TagIndex->match($1, $op, $v1, $v2));
	}

	my $def = $FIELDS{$field} or return {};
	my ($cond, @bind) = $def->{type} eq 'text'
		? _textCond($def->{col}, $op, $v1, $def->{normalise})
		: _numCond($def->{col}, $op, $v1, $v2);
	return {} unless $cond;

	my $now = int(time());
	my $sql = "SELECT DISTINCT t.urlmd5 FROM $def->{from} WHERE "
	        . join(' AND ', grep { defined } $def->{where}, $cond);
	$sql =~ s/%NOW%/$now/g;

	return _set(_query($sql, @bind));
}

# SQL condition and bind values for a text operator (LIKE with escaped wildcards).
sub _textCond {
	my ($col, $op, $value, $normalise) = @_;
	return ("($col IS NOT NULL AND $col <> '')") if $op eq 'isset';
	my $pattern = Plugins::JukeboxMoods::TagIndex::likePattern($op, $value, $normalise);
	return unless defined $pattern;
	return ("$col LIKE ? ESCAPE '\\'", $pattern);
}

# numbers are validated and inlined: SQLite would otherwise compare a bound
# text value against a computed numeric expression as text
sub _numCond {
	my ($expr, $op, $v1, $v2) = @_;
	return unless _isNum($v1);
	return ("$expr $CMP{$op} " . (0 + $v1)) if $CMP{$op};
	if ($op eq 'between' && _isNum($v2)) {
		my ($lo, $hi) = sort { $a <=> $b } (0 + $v1, 0 + $v2);
		return ("$expr BETWEEN $lo AND $hi");
	}
	return;
}

# True for a plain integer or decimal number.
sub _isNum {
	my $v = shift;
	return defined $v && $v =~ /^\s*-?\d+(?:\.\d+)?\s*$/;
}

# Tracks LMS recorded as played within the repeat window (undef when protection is off).
sub _blockedSet {
	return unless $prefs->get('repeatProtect');
	my $since = int(time()) - ($prefs->get('repeatMinutes') || 60) * 60;
	return _set(_query("SELECT urlmd5 FROM tracks_persistent WHERE lastPlayed > $since"));
}

# Map urlmd5 -> URL for a list of tracks.
sub _urlsFor {
	my $md5s = shift;
	return {} unless @$md5s;
	my $in   = join(',', ('?') x @$md5s);
	my $rows = eval { Slim::Schema->dbh->selectall_arrayref("SELECT urlmd5, url FROM tracks WHERE urlmd5 IN ($in)", undef, @$md5s) };
	if ($@ || !$rows) {
		_log()->error('URL lookup failed: ' . ($@ || 'no result'));
		return {};
	}
	return { map { $_->[0] => $_->[1] } @$rows };
}

# Run a single-column query against the LMS library; logs the SQL on failure.
sub _query {
	my ($sql, @bind) = @_;
	my $rows = eval { Slim::Schema->dbh->selectcol_arrayref($sql, undef, @bind) };
	if ($@ || !$rows) {
		_log()->error('Library query failed: ' . ($@ || 'no result') . " -- SQL: $sql");
		return [];
	}
	return $rows;
}

# Turn a list into a set (hash with the list items as keys).
sub _set {
	my $list = shift || [];
	my %s;
	@s{@$list} = ();
	return \%s;
}

# Cache key for a mood's candidate list: its rules plus generation counters
# that change after an LMS rescan or a tag index run.
sub _cacheKey {
	my $profile = shift;
	local $Data::Dumper::Sortkeys = 1;
	local $Data::Dumper::Indent   = 0;
	local $Data::Dumper::Terse    = 1;
	return join('|',
		$libraryGeneration,
		Plugins::JukeboxMoods::TagIndex->generation,
		Data::Dumper::Dumper([ $profile->{match}, $profile->{rules}, $profile->{exclude} ]),
	);
}

1;

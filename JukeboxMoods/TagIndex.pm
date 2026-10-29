package Plugins::JukeboxMoods::TagIndex;

# =============================================================================
# Jukebox Moods - file tag indexer
# Part of Jukebox Moods. Licensed under the GNU GPL v2 or later (see LICENSE).
# When "Scan additional tags" is on, reads every extra tag found in your music
# files (anything LMS does not already store, such as MOOD, ENERGY or
# GROUPING) and keeps the values in a small SQLite database in the LMS cache
# folder. The tag names found become rule fields in the mood editor.
#
# Indexing runs in the server after each library scan finishes, a few files
# at a time, and only re-reads files whose modification time changed.
#
# Database file: <LMS cache folder>/jukeboxmoods.db (safe to delete; rebuilt)
#   files (urlmd5 PRIMARY KEY, mtime, tagset)  - what has been indexed, and how
#   tags  (urlmd5, tag, value, value_search)   - one row per tag value;
#         value_search is upper-cased and accent-stripped for matching
#
# Design note: LMS scans in a separate scanner process. Indexing here, in the
# server process after the scan, keeps the plugin simple and independent of
# the scanner's plugin hooks, at the cost of tags appearing slightly later.
# =============================================================================

use strict;
use warnings;

use DBI;
use File::Spec::Functions qw(catfile);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Scheduler;
use Slim::Utils::Text;
use Slim::Utils::Timers;

use constant BATCH_SIZE => 20;

my $prefs       = preferences('plugin.jukeboxmoods');
my $serverPrefs = preferences('server');

my $log;
sub _log { $log ||= logger('plugin.jukeboxmoods') }

my $dbh;
my $generation = 0;
my $running    = 0;
my ($pending, $pendingForce) = (0, 0);
my (@queue, $tagset);
my %status = (state => 'idle', indexed => 0, total => 0, done => 0, lastRun => 0);

use constant INDEX_VERSION => 'all:2';   # change to force a full re-read after logic changes

# Alternative names for the same tag in different formats -> one friendly name.
my %ALIAS = (
	TMOO => 'MOOD',
	TIT1 => 'GROUPING', GRP1 => 'GROUPING', CONTENTGROUP => 'GROUPING',
	TKEY => 'KEY', INITIALKEY => 'KEY', INITIAL_KEY => 'KEY',
	TLAN => 'LANGUAGE',
);

# Tags LMS already stores (they are library fields in the editor) and
# technical values from the tag reader. These are not offered as file tags.
my %SKIP = map { $_ => 1 } qw(
	TITLE ARTIST ALBUM ALBUMARTIST TRACKARTIST COMPOSER CONDUCTOR BAND GENRE YEAR DATE ORIGINALDATE
	TRACKNUM TRACKNUMBER TRACKTOTAL TOTALTRACKS DISC DISCNUMBER DISCC DISCTOTAL TOTALDISCS
	COMMENT COMMENTS DESCRIPTION BPM TBPM COMPILATION LYRICS UNSYNCEDLYRICS USLT
	COVER COVERART PIC PICTURE APIC COVR ARTWORK METADATA_BLOCK_PICTURE
	ENCODER ENCODED_BY ENCODEDBY ENCODING TOOL VENDOR SOFTWARE TSSE TENC
	SIZE SECS OFFSET AUDIO_OFFSET AUDIO_SIZE BITRATE VBR_SCALE RATE SAMPLESIZE BITS_PER_SAMPLE
	CHANNELS LOSSLESS BLOCKALIGN BLOCK_ALIGNMENT ENDIAN DLNA_PROFILE CONTENT_TYPE CT DRM FILESIZE
	TAGVERSION STEREO LAYER MPEG_VERSION TIMESTAMP VIRTUAL START END URL FILENAME MD5 FRAMES
	SAMPLES TOTAL_SAMPLES SONG_LENGTH_MS LENGTH TLEN DURATION REMOTE AUDIO ID3 TXXX
);
my $SKIP_RE = qr/^(?:REPLAYGAIN|MUSICBRAINZ|MUSICIP|ACOUSTID|ITUNES|DISCOGS|_)|SORT(?:ORDER)?$/;

my %CMP = (gt => '>', gte => '>=', lt => '<', lte => '<=');

# ---------------------------------------------------------------- public

# Called from Plugin::initPlugin. Opens the database, watches the scan switch,
# and schedules a first check shortly after LMS has started.
sub init {
	my $class = shift;
	_connect() or return;
	_updateCount();
	$prefs->setChange(sub { $class->start(0) }, 'scanCustomTags');
	# initial check once the server has settled
	Slim::Utils::Timers::setTimer($class, time() + 45, sub { $class->start(0) });
}

# Stop indexing and close the database.
sub shutdown {
	@queue = ();
	$running = 0;
	if ($dbh) { eval { $dbh->disconnect }; undef $dbh; }
}

# Counter bumped after every index run; part of Selector's cache key.
sub generation { $generation }

# Indexer status for the settings page.
sub status {
	return { %status, tagCount => scalar @{ discoveredTags() } };
}

# Tag names are compared in upper case; returns undef for unusable names.
sub normaliseTag {
	my $tag = shift;
	return unless defined $tag;
	$tag =~ s/^\s+|\s+$//g;
	$tag = uc $tag;
	return unless length $tag && length $tag <= 64 && $tag !~ /[,\x00-\x1f]/;
	return $tag;
}

# True when 'Scan additional tags from my music files' is switched on.
sub scanning { $prefs->get('scanCustomTags') ? 1 : 0 }

# file tags found so far, with how many tracks carry each: [ [TAG, count], ... ]
sub discoveredTags {
	return [] unless scanning() && _connect();
	my $rows = eval { $dbh->selectall_arrayref('SELECT tag, COUNT(DISTINCT urlmd5) FROM tags GROUP BY tag ORDER BY tag') };
	return $rows || [];
}

# Build an SQL LIKE pattern for a text operator, escaping % _ and \ in the
# user's value. With $normalise the value is folded the same way LMS builds
# its *search columns (upper case, accents removed).
sub likePattern {
	my ($op, $value, $normalise) = @_;
	$value = '' unless defined $value;
	$value = Slim::Utils::Text::ignoreCase($value, 1) if $normalise;
	$value =~ s/([\\%_])/\\$1/g;
	return $op eq 'is'         ? $value
	     : $op eq 'contains'   ? "%$value%"
	     : $op eq 'startswith' ? "$value%"
	     : undef;
}

# Tracks (urlmd5 values) whose file tag $tag matches the operator and value.
# Text operators use value_search; numeric operators only consider values
# that look like numbers.
sub match {
	my ($class, $tag, $op, $v1, $v2) = @_;
	$tag = normaliseTag($tag) or return [];
	_connect() or return [];

	my $sql  = 'SELECT DISTINCT urlmd5 FROM tags WHERE tag = ?';
	my @bind = ($tag);

	if ($op eq 'isset') {
		$sql .= " AND value IS NOT NULL AND value <> ''";
	}
	elsif ($CMP{$op} || $op eq 'eq' || $op eq 'between') {
		return [] unless _isNum($v1);
		$sql .= " AND value GLOB '[0-9.-]*' AND CAST(value AS REAL)";
		if ($op eq 'between') {
			return [] unless _isNum($v2);
			my ($lo, $hi) = sort { $a <=> $b } (0 + $v1, 0 + $v2);
			$sql .= " BETWEEN $lo AND $hi";
		}
		else {
			$sql .= ' ' . ($CMP{$op} || '=') . ' ' . (0 + $v1);
		}
	}
	else {
		my $pattern = likePattern($op, $v1, 1);
		return [] unless defined $pattern;
		$sql .= " AND value_search LIKE ? ESCAPE '\\'";
		push @bind, $pattern;
	}

	my $rows = eval { $dbh->selectcol_arrayref($sql, undef, @bind) };
	if ($@ || !$rows) {
		_log()->error('Custom tag query failed: ' . ($@ || 'no result'));
		return [];
	}
	return $rows;
}

# Start an index run (no-op while LMS is still scanning). Only new or changed
# files are read unless $force is set. Runs in small slices through
# Slim::Utils::Scheduler so the server stays responsive.
sub start {
	my ($class, $force) = @_;

	if ($running) {
		$pending = 1;
		$pendingForce ||= $force ? 1 : 0;
		return;
	}

	# wait for the library scan to finish; the rescan-done event restarts us
	return if eval { Slim::Music::Import->stillScanning };

	_connect() or return;

	if (!scanning()) {
		eval { $dbh->do('DELETE FROM tags'); $dbh->do('DELETE FROM files'); };
		$generation++;
		%status = (%status, state => 'idle', indexed => 0, total => 0, done => 0);
		return;
	}

	$tagset = INDEX_VERSION;

	my $tracks = eval {
		Slim::Schema->dbh->selectall_arrayref('SELECT urlmd5, url, timestamp FROM tracks WHERE audio = 1 AND remote = 0')
	};
	if ($@ || !$tracks) {
		_log()->error('Could not read track list: ' . ($@ || 'no result'));
		return;
	}

	my $known = eval { $dbh->selectall_hashref('SELECT urlmd5, mtime, tagset FROM files', 'urlmd5') } || {};

	my %present;
	@queue = ();
	for my $row (@$tracks) {
		my ($md5, $url, $mtime) = @$row;
		next unless $md5 && $url && $url =~ /^file:/;
		$present{$md5} = 1;
		my $k = $known->{$md5};
		next if !$force && $k
			&& ($k->{mtime} || 0) == ($mtime || 0)
			&& ($k->{tagset} || '') eq $tagset;
		push @queue, [ $md5, $url, $mtime || 0 ];
	}

	my @stale = grep { !$present{$_} } keys %$known;
	_deleteMd5s(\@stale) if @stale;

	%status = (%status, total => scalar(@queue), done => 0);

	if (!@queue) {
		$generation++ if @stale;
		$status{state}   = 'idle';
		$status{lastRun} = time();
		_updateCount();
		return;
	}

	_log()->info('Indexing custom tags in ' . scalar(@queue) . ' file(s)');
	$running = 1;
	$status{state} = 'indexing';
	Slim::Utils::Scheduler::add_task(\&_work);
}

# ---------------------------------------------------------------- internals

# Location of the index database.
sub _dbFile { catfile($serverPrefs->get('cachedir'), 'jukeboxmoods.db') }

# Open (and if needed create) the index database.
sub _connect {
	return $dbh if $dbh;
	$dbh = eval {
		DBI->connect('dbi:SQLite:dbname=' . _dbFile(), '', '', {
			RaiseError => 1, PrintError => 0, AutoCommit => 1, sqlite_unicode => 1,
		});
	};
	unless ($dbh) {
		_log()->error("Cannot open the custom tag database: $@");
		return;
	}
	eval {
		$dbh->do('PRAGMA synchronous = NORMAL');
		$dbh->do('CREATE TABLE IF NOT EXISTS files (urlmd5 TEXT PRIMARY KEY, mtime INTEGER, tagset TEXT)');
		$dbh->do('CREATE TABLE IF NOT EXISTS tags (urlmd5 TEXT NOT NULL, tag TEXT NOT NULL, value TEXT, value_search TEXT)');
		$dbh->do('CREATE INDEX IF NOT EXISTS tags_tag_search ON tags (tag, value_search)');
		$dbh->do('CREATE INDEX IF NOT EXISTS tags_md5 ON tags (urlmd5)');
	};
	_log()->error("Custom tag database setup failed: $@") if $@;
	return $dbh;
}

# One scheduler slice: index up to BATCH_SIZE files in one transaction.
# Returns 1 while there is more to do, 0 when finished.
sub _work {
	return 0 unless $dbh && $running;

	my $ok = eval {
		$dbh->begin_work;
		my $del  = $dbh->prepare_cached('DELETE FROM tags WHERE urlmd5 = ?');
		my $ins  = $dbh->prepare_cached('INSERT INTO tags (urlmd5, tag, value, value_search) VALUES (?, ?, ?, ?)');
		my $file = $dbh->prepare_cached('INSERT OR REPLACE INTO files (urlmd5, mtime, tagset) VALUES (?, ?, ?)');

		my $n = BATCH_SIZE;
		while ($n-- > 0 && (my $item = shift @queue)) {
			my ($md5, $url, $mtime) = @$item;
			my $values = _readTags($url);
			$del->execute($md5);
			for my $tag (keys %$values) {
				$ins->execute($md5, $tag, $_, Slim::Utils::Text::ignoreCase($_, 1)) for @{ $values->{$tag} };
			}
			$file->execute($md5, $mtime, $tagset);
			$status{done}++;
		}
		$dbh->commit;
		1;
	};

	unless ($ok) {
		_log()->error("Custom tag indexing failed: $@");
		eval { $dbh->rollback };
		@queue = ();
	}

	return 1 if @queue;
	_finish();
	return 0;
}

# End of a run: bump the generation, update status, start any queued run.
sub _finish {
	$running = 0;
	$generation++;
	$status{state}   = 'idle';
	$status{lastRun} = time();
	_updateCount();
	_log()->info("Custom tag index complete ($status{done} file(s) read)");

	if ($pending) {
		my $force = $pendingForce;
		$pending = $pendingForce = 0;
		__PACKAGE__->start($force);
	}
}

# Read one file with LMS's own tag reader and return { TAG => [values] } for
# every tag worth offering as a rule field (see %ALIAS, %SKIP and $SKIP_RE).
sub _readTags {
	my $url = shift;

	my $tags = eval { Slim::Formats->readTags($url) };
	if ($@ || ref $tags ne 'HASH') {
		_log()->warn("Could not read tags from $url" . ($@ ? ": $@" : ''));
		return {};
	}

	my %all;
	for my $key (keys %$tags) {
		my $value = $tags->{$key};
		if (uc($key) eq 'TXXX' && ref $value eq 'ARRAY') {
			# ID3 user-defined text frames: [description, value] pairs
			my @frames = (@$value && ref $value->[0]) ? @$value : ($value);
			for my $frame (@frames) {
				if (ref $frame eq 'ARRAY' && @$frame >= 2) {
					push @{ $all{ uc $frame->[0] } }, @$frame[ 1 .. $#$frame ];
				}
				elsif (ref $frame eq 'HASH') {
					my $d = defined $frame->{description} ? $frame->{description} : $frame->{desc};
					my $t = defined $frame->{text} ? $frame->{text} : $frame->{value};
					push @{ $all{ uc $d } }, $t if defined $d;
				}
			}
			next;
		}
		push @{ $all{ uc $key } }, ref $value eq 'ARRAY' ? @$value : $value;
	}

	_log()->debug("Tags found in $url: " . join(', ', sort keys %all)) if _log()->is_debug;

	my %out;
	for my $key (keys %all) {
		my $tag = $ALIAS{$key} || $key;
		next if $SKIP{$tag} || $tag =~ $SKIP_RE || $tag !~ /^[A-Z0-9][A-Z0-9 _.:\-]{0,63}$/;
		my $seen = $out{$tag} ||= [];
		my %have = map { lc($_) => 1 } @$seen;
		for my $raw (@{ $all{$key} }) {
			next if !defined $raw || ref $raw;
			(my $v = $raw) =~ s/^\s+|\s+$//g;
			next unless length $v && length $v <= 200;
			push @$seen, $v unless $have{ lc $v }++;
		}
		delete $out{$tag} unless @$seen;
	}
	return \%out;
}

# Remove index rows for tracks that are no longer in the LMS library.
sub _deleteMd5s {
	my $list = shift;
	eval {
		$dbh->begin_work;
		while (my @chunk = splice(@$list, 0, 200)) {
			my $in = join(',', ('?') x @chunk);
			$dbh->do("DELETE FROM tags WHERE urlmd5 IN ($in)", undef, @chunk);
			$dbh->do("DELETE FROM files WHERE urlmd5 IN ($in)", undef, @chunk);
		}
		$dbh->commit;
	};
	if ($@) {
		_log()->error("Could not remove stale index entries: $@");
		eval { $dbh->rollback };
	}
}

# Refresh the 'tracks with file tags' figure shown on the settings page.
sub _updateCount {
	return unless $dbh;
	($status{indexed}) = eval { $dbh->selectrow_array('SELECT COUNT(DISTINCT urlmd5) FROM tags') };
	$status{indexed} ||= 0;
}

# True for a plain integer or decimal number.
sub _isNum {
	my $v = shift;
	return defined $v && $v =~ /^\s*-?\d+(?:\.\d+)?\s*$/;
}

1;

package Plugins::JukeboxMoods::Events;

# =============================================================================
# Jukebox Moods - events (planned sequences of moods)
# Part of Jukebox Moods. Licensed under the GNU GPL v2 or later (see LICENSE).
#
# An event is an ordered list of slots; each slot is a mood plus a duration
# in minutes (the last slot may be "until stopped", duration 0). An event is
# started manually (My Apps, CLI) or automatically at a date and time.
#
# The event only decides WHICH mood is active and when it changes. Everything
# else - rules, fallbacks, guest requests, repeat protection, the Don't Stop
# The Music trigger - works exactly as without an event.
#
# Stored event (preference "events"):
#   { id, name,
#     startMode  => 'manual' | 'scheduled',
#     startAt    => 'YYYY-MM-DDTHH:MM' (server local time; scheduled only),
#     player     => player id, or '' = the player it is started from,
#     endAction  => 'stay' | 'picked' | 'stop',
#     changeMode => 'songend' | 'immediate',
#     slots      => [ { mood => mood id, minutes => N (0 = until stopped) } ] }
#
# Running state, per player (client preference "eventState", so it survives
# an LMS restart):
#   { eventId, startedAt (epoch of slot 1's start), slot (index applied
#     last), prevChosen (the mood the user had picked before the event) }
# The current slot is always worked out from the clock, so a restart or a
# player that was offline simply resumes at the right slot.
#
# A timer ticks every TICK seconds: it starts scheduled events that are due
# and applies slot changes for running events.
# =============================================================================

use strict;
use warnings;

# POSIX only: LMS relies on it on every platform. (Time::Local may be missing from
# the trimmed-down Perl that ships with LMS for Windows.)
use POSIX qw(strftime mktime);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use constant TICK => 20;   # seconds between checks

my $prefs = preferences('plugin.jukeboxmoods');

my $log;
sub _log { $log ||= logger('plugin.jukeboxmoods') }

my %END_ACTIONS  = map { $_ => 1 } qw(stay picked stop);
my %CHANGE_MODES = map { $_ => 1 } qw(songend immediate);

# ---------------------------------------------------------------- set-up

# Called from Plugin::initPlugin: start the event clock.
sub init {
	my $class = shift;
	Slim::Utils::Timers::setTimer($class, time() + 10, \&_tick);
}

sub shutdown {
	Slim::Utils::Timers::killTimers(__PACKAGE__, \&_tick);
}

# ---------------------------------------------------------------- stored events

sub events {
	my $e = $prefs->get('events');
	return ref $e eq 'ARRAY' ? $e : [];
}

sub eventById {
	my $id = shift;
	return unless defined $id && length $id;
	for my $e (@{ events() }) {
		return $e if $e->{id} eq $id;
	}
	return;
}

# Look up an event by id or, failing that, by name (case-insensitive). Used by the CLI.
sub findEvent {
	my $key = shift;
	return unless defined $key && length $key;
	return eventById($key) || (grep { lc($_->{name}) eq lc($key) } @{ events() })[0];
}

# Validate one event from the settings page. $moodIds is a set of valid mood ids.
sub sanitiseEvent {
	my ($e, $moodIds) = @_;
	my $name = defined $e->{name} && !ref $e->{name} ? $e->{name} : '';
	$name =~ s/^\s+|\s+$//g;
	$name = 'Untitled event' unless length $name;

	my $startAt = (defined $e->{startAt} && $e->{startAt} =~ /^\d{4}-\d\d-\d\dT\d\d:\d\d$/) ? $e->{startAt} : '';
	my $mode    = (($e->{startMode} || '') eq 'scheduled' && $startAt) ? 'scheduled' : 'manual';
	my $player  = (defined $e->{player} && !ref $e->{player} && $e->{player} =~ /^[\w:.\-]{1,64}$/) ? $e->{player} : '';

	my @slots;
	for my $s (ref $e->{slots} eq 'ARRAY' ? @{ $e->{slots} } : ()) {
		next unless ref $s eq 'HASH' && defined $s->{mood} && $moodIds->{ $s->{mood} };
		my $min = defined $s->{minutes} && $s->{minutes} =~ /^\d+$/ ? 0 + $s->{minutes} : 60;
		$min = 1440 if $min > 1440;
		push @slots, { mood => $s->{mood}, minutes => $min };
		last if @slots >= 50;
	}
	# only the last slot may be "until stopped" (0); anywhere else 0 becomes 1 minute
	$_->{minutes} ||= 1 for @slots[ 0 .. $#slots - 1 ];

	return {
		id         => (defined $e->{id} && $e->{id} =~ /^[A-Za-z0-9_-]{1,40}$/) ? $e->{id} : 'e' . join('', map { ('a'..'z', 0..9)[rand 36] } 1 .. 10),
		name       => substr($name, 0, 80),
		startMode  => $mode,
		startAt    => $startAt,
		player     => $player,
		endAction  => $END_ACTIONS{ $e->{endAction} || '' } ? $e->{endAction} : 'picked',
		changeMode => $CHANGE_MODES{ $e->{changeMode} || '' } ? $e->{changeMode} : 'songend',
		slots      => \@slots,
	};
}

# ---------------------------------------------------------------- timing helpers

# 'YYYY-MM-DDTHH:MM' (server local time) -> epoch seconds, or undef
sub parseStart {
	my $s = shift;
	return unless defined $s && $s =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d)$/;
	my $t = mktime(0, $5, $4, $3, $2 - 1, $1 - 1900, 0, 0, -1);   # -1: let the system work out summer time
	return defined $t && $t > 0 ? $t : undef;
}

# Start offset (seconds from the event start) of every slot, and the event's
# total length in seconds - undef when the last slot is "until stopped".
sub offsets {
	my $event = shift;
	my (@off, $t);
	$t = 0;
	for my $slot (@{ $event->{slots} || [] }) {
		push @off, $t;
		$t += ($slot->{minutes} || 0) * 60;
	}
	my $slots = $event->{slots} || [];
	my $open  = @$slots && !$slots->[-1]{minutes};
	return (\@off, $open ? undef : $t);
}

# Which slot is current at $now: -1 before the start, the slot index while
# running, or the number of slots once the event has finished.
sub slotAt {
	my ($event, $startedAt, $now) = @_;
	my ($off, $total) = offsets($event);
	return scalar(@$off) unless @$off;
	my $elapsed = $now - $startedAt;
	return -1 if $elapsed < 0;
	return scalar(@$off) if defined $total && $elapsed >= $total;
	my $i = 0;
	for my $k (0 .. $#$off) { $i = $k if $off->[$k] <= $elapsed }
	return $i;
}

# When slot $i ends (epoch), or undef for an open-ended last slot.
sub slotEnd {
	my ($event, $startedAt, $i) = @_;
	my ($off, $total) = offsets($event);
	return $startedAt + $off->[ $i + 1 ] if $i < $#$off;
	return defined $total ? $startedAt + $total : undef;
}

sub clock { strftime('%H:%M', localtime(shift)) }

# ---------------------------------------------------------------- running state

sub state {
	my $client = shift or return;
	my $s = $prefs->client($client->master)->get('eventState');
	return ref $s eq 'HASH' ? $s : undef;
}

sub _setState {
	my ($client, $state) = @_;
	$prefs->client($client->master)->set('eventState', $state || '');
}

# The running event on this player and its current slot index, if any.
sub running {
	my $client = shift;
	my $st = state($client) or return;
	my $event = eventById($st->{eventId}) or return;
	return ($event, slotAt($event, $st->{startedAt}, time()), $st);
}

# Scheduled events whose start is still to come and not cancelled.
sub isPending {
	my $event = shift;
	return 0 unless $event->{startMode} eq 'scheduled';
	my $start = parseStart($event->{startAt}) or return 0;
	my $done  = $prefs->get('eventsDone') || {};
	return 0 if ($done->{ $event->{id} } || '') eq $event->{startAt};
	return $start > time() ? 1 : 0;
}

# Remember that a scheduled event has been started or cancelled, so the
# timer does not start it (again) for this start time.
sub _markDone {
	my $event = shift;
	my $done = { %{ $prefs->get('eventsDone') || {} } };
	return if ($done->{ $event->{id} } || '') eq $event->{startAt};
	$done->{ $event->{id} } = $event->{startAt};
	$prefs->set('eventsDone', $done);
}

# ---------------------------------------------------------------- actions

# Start $event on $client. $startedAt defaults to now ("Start now" shifts a
# scheduled event's times); a scheduled start passes its planned time, so a
# late start joins at the slot that is current.
sub start {
	my ($class, $client, $event, $startedAt) = @_;
	$client = $client->master;
	return 0 unless @{ $event->{slots} || [] };

	my $old = state($client);
	my $prevChosen = $old ? $old->{prevChosen} : ($prefs->client($client)->get('chosenMood') || '');

	_markDone($event) if $event->{startMode} eq 'scheduled';
	_setState($client, { eventId => $event->{id}, startedAt => $startedAt || time(), slot => -2, prevChosen => $prevChosen });
	$prefs->client($client)->set('stopAdding', 0);

	eval { $client->execute(['power', 1]) unless $client->power };
	_log()->info("Event '$event->{name}' started on " . $client->name);
	_apply($client, time(), 1);
	return 1;
}

# Stop the running event; the current mood keeps playing.
sub stop {
	my ($class, $client) = @_;
	my ($event) = running($client) or return 0;
	_setState($client, undef);
	_log()->info("Event '$event->{name}' stopped on " . $client->name);
	return 1;
}

# Skip to the next slot (or finish the event if this is the last slot).
sub nextSlot {
	my ($class, $client) = @_;
	my ($event, $i, $st) = running($client) or return 0;
	my ($off) = offsets($event);
	if ($i >= $#$off) {
		_finish($client, $event, $st);
		return 1;
	}
	$st->{startedAt} = time() - $off->[ $i + 1 ];   # shift the event so the next slot starts now
	_setState($client, $st);
	_apply($client, time());
	return 1;
}

# Cancel a scheduled event's upcoming start.
sub cancel {
	my ($class, $event) = @_;
	return 0 unless isPending($event);
	_markDone($event);
	return 1;
}

# ---------------------------------------------------------------- the clock

sub _tick {
	my $now = time();
	eval {
		# 1. scheduled events that are due
		for my $event (@{ events() }) {
			next unless $event->{startMode} eq 'scheduled';
			my $start = parseStart($event->{startAt}) or next;
			my $done  = $prefs->get('eventsDone') || {};
			next if ($done->{ $event->{id} } || '') eq $event->{startAt} || $now < $start;

			my (undef, $total) = offsets($event);
			if (defined $total && $now >= $start + $total) {   # missed completely (e.g. server was off)
				_markDone($event);
				next;
			}
			# start once the player is connected; until then, keep checking
			my $client = Slim::Player::Client::getClient($event->{player}) or next;
			__PACKAGE__->start($client, $event, $start);
		}

		# 2. slot changes for running events (once per sync group)
		my %seen;
		for my $client (Slim::Player::Client::clients()) {
			my $master = $client->master;
			next if $seen{ $master->id }++;
			_apply($master, $now) if state($master);
		}
	};
	_log()->error("Event timer: $@") if $@;
	Slim::Utils::Timers::setTimer(__PACKAGE__, time() + TICK, \&_tick);
}

# Bring the player in line with its running event: change mood when a new
# slot has begun, finish the event when its last slot is over. $first is set
# when the event has just been started (the music is started if idle).
sub _apply {
	my ($client, $now, $first) = @_;
	my $st = state($client) or return;
	my $event = eventById($st->{eventId});
	unless ($event && @{ $event->{slots} || [] }) {   # event deleted or emptied
		_setState($client, undef);
		return;
	}

	my $i = slotAt($event, $st->{startedAt}, $now);
	return if $i < 0;
	if ($i >= @{ $event->{slots} }) {
		_finish($client, $event, $st);
		return;
	}
	return if $i == ($st->{slot} // -2);

	$st->{slot} = $i;
	_setState($client, $st);

	my $mood = Plugins::JukeboxMoods::Plugin::profileById($event->{slots}[$i]{mood});
	unless ($mood) {
		_log()->warn("Event '$event->{name}': the mood for slot " . ($i + 1) . ' no longer exists');
		return;
	}
	_log()->info("Event '$event->{name}': slot " . ($i + 1) . " - mood '$mood->{name}'");
	_changeTo($client, $mood, $event->{changeMode}, $first);
}

# Switch the player to $mood the way the event asks:
#   * just started and nothing playing -> clear the queue and play the mood
#   * songend   -> the current song finishes; queued mood tracks are replaced
#   * immediate -> as songend, and if the current song was added by this
#                  plugin it is skipped (guest requests are never cut)
sub _changeTo {
	my ($client, $mood, $changeMode, $first) = @_;
	my $playing = eval { Slim::Player::Source::playmode($client) eq 'play' } || 0;

	if ($first && !$playing) {
		Plugins::JukeboxMoods::Plugin::switchMood($client, $mood, 'play');
		return;
	}

	my $skip = $playing && $changeMode eq 'immediate' && Plugins::JukeboxMoods::Plugin::currentIsMoodTrack($client);
	Plugins::JukeboxMoods::Plugin::switchMood($client, $mood, 'replace');
	$client->execute(['playlist', 'index', '+1']) if $skip;
}

# The last slot is over: do what the event's "when it ends" setting says.
sub _finish {
	my ($client, $event, $st) = @_;
	_setState($client, undef);
	my $end = $event->{endAction} || 'picked';
	_log()->info("Event '$event->{name}' finished on " . $client->name . " ($end)");

	if ($end eq 'picked') {
		my $mood = Plugins::JukeboxMoods::Plugin::profileById($st->{prevChosen});
		Plugins::JukeboxMoods::Plugin::switchMood($client, $mood, 'replace') if $mood;
	}
	elsif ($end eq 'stop') {
		# add nothing more: the queue plays out (guest requests included), then the music stops
		$prefs->client($client->master)->set('stopAdding', 1);
	}
	# 'stay': keep playing the last slot's mood
}

1;

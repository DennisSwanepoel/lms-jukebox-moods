package Plugins::JukeboxMoods::Settings;

# =============================================================================
# Jukebox Moods - settings page handler
# Part of Jukebox Moods. Licensed under the GNU GPL v2 or later (see LICENSE).
#
# Server-wide settings page: Settings > Plugins > Jukebox Moods.
# The mood editor itself is JavaScript in the template; it sends the whole
# mood list back as JSON in the hidden field "profiles_json".
# =============================================================================

use strict;
use warnings;

use base qw(Slim::Web::Settings);

use JSON::XS::VersionOneAndTwo;

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.jukeboxmoods');

# Settings page title (strings.txt token), registered with CSRF protection.
sub name { Slim::Web::HTTP::CSRF->protectName('PLUGIN_JUKEBOXMOODS') }

# Template for the page (HTML/EN/plugins/JukeboxMoods/settings/basic.html).
sub page { Slim::Web::HTTP::CSRF->protectURI('plugins/JukeboxMoods/settings/basic.html') }

# Simple preferences that Slim::Web::Settings loads into the form (as
# prefs.pref_<name>) and saves back automatically when the page is saved.
sub prefs {
	return ($prefs, qw(tracksPerTopup repeatProtect repeatMinutes announceFallback scanCustomTags));
}

# Runs on every page load and save. Saves the mood editor's JSON (which the
# base class can't handle), then supplies the data the template and the
# editor's JavaScript need.
sub handler {
	my ($class, $client, $params, $callback, @args) = @_;

	if ($params->{saveSettings}) {
		if (defined $params->{profiles_json} && length $params->{profiles_json}) {
			my $data = Plugins::JukeboxMoods::Plugin::decodeJson($params->{profiles_json});
			if (ref $data eq 'ARRAY') {
				my @clean = map { Plugins::JukeboxMoods::Plugin::sanitiseProfile($_) } grep { ref $_ eq 'HASH' } @$data;
				my %ids = map { $_->{id} => 1 } @clean;
				for my $p (@clean) {
					# special values are kept as they are; mood ids must still exist
					next if $p->{fallback} =~ /^__\w+__$/;
					$p->{fallback} = Plugins::JukeboxMoods::Plugin::CHOSEN_FALLBACK()
						if !$ids{ $p->{fallback} } || $p->{fallback} eq $p->{id};
				}
				$prefs->set('profiles', \@clean);
			}
			else {
				$params->{warning} .= 'The mood editor data could not be read, so moods were not changed. ';
			}
		}
		Plugins::JukeboxMoods::TagIndex->start(1) if $params->{reindex};
	}

	# library fields; the editor adds the file tags found by the scan
	$params->{jm_fields} = _scriptJson(Plugins::JukeboxMoods::Selector->fieldList([]));
	$params->{jm_tags}   = _scriptJson([ map { { tag => $_->[0], tracks => $_->[1] } } @{ Plugins::JukeboxMoods::TagIndex->discoveredTags } ]);
	$params->{jm_ops}      = _scriptJson(Plugins::JukeboxMoods::Selector->operators);
	$params->{jm_profiles} = _scriptJson($prefs->get('profiles') || []);

	# "Getting started" box: which connected players already use Jukebox Moods
	# for Don't Stop The Music (the DSTM plugin keeps its choice in the
	# per-player preference plugin.dontstopthemusic:provider).
	my (@active, @inactive);
	eval {
		my $dstm = preferences('plugin.dontstopthemusic');
		for my $c (Slim::Player::Client::clients()) {
			my $provider = $dstm->client($c->master)->get('provider') || '';
			if ($provider eq Plugins::JukeboxMoods::Plugin::DSTM_TOKEN()) { push @active, $c->name }
			else { push @inactive, $c->name }
		}
	};
	$params->{jm_hasMoods}        = @{ $prefs->get('profiles') || [] } ? 1 : 0;
	$params->{jm_activePlayers}   = join(', ', sort @active);
	$params->{jm_inactivePlayers} = join(', ', sort @inactive);
	$params->{jm_playerCount}     = @active + @inactive;

	my $status = Plugins::JukeboxMoods::TagIndex->status;
	$status->{lastRunText} = $status->{lastRun} ? scalar localtime($status->{lastRun}) : 'never';
	$params->{jm_status} = $status;

	return $class->SUPER::handler($client, $params, $callback, @args);
}

# JSON that is safe to place inside a <script> element
# JSON that is safe to place inside a <script> element.
sub _scriptJson {
	my $json = to_json(shift);
	$json =~ s/</\\u003c/g;
	$json =~ s/>/\\u003e/g;
	$json =~ s/&/\\u0026/g;
	return $json;
}

1;

#!/usr/bin/perl

use strict;
use warnings;
use 5.10.0;

use Getopt::Long;
use JSON::XS;
use YAML::Tiny;
use AnyEvent::HTTP;

our $configHash = YAML::Tiny->read('iotawatt_config.yaml');
$configHash = $configHash->[0];

BEGIN {
	use Cwd qw( abs_path getcwd );
	use File::Basename;
	my %constants = (
		CWD => getcwd(),
		PREFIX => dirname(abs_path($0)),
	);
	require constant; import constant(\%constants);
}

our %units = map { $_ => {}  } @{$configHash->{iotawatts}};
#our %units = map { $_ => {}  } qw( iwbsmt.tabris.net );
our $updateInterval = $configHash->{update_interval};

# used to determine if we've published the HA discovery topics recently
our %discoveryTopicsMQTT;
# is 60 seconds good? 300?
# the idea is we don't want to update every 5 seconds, but we don't want to set retain either.
our $discoveryTimer = AnyEvent->timer( interval => 60, cb => sub { %discoveryTopicsMQTT = () } );
#our $baseURI = 'status?state&inputs&outputs&stats&wifi&datalogs&influx1&influx2&emoncms&pvoutput';
# we don't have emoncms or pvoutput, and we don't have influx1 anymore
our $baseURI = 'status?state&inputs&outputs&stats&wifi&datalogs&influx2';
our $IWconfigURI = 'config.txt'; #note it's really JSON

chdir PREFIX;
use lib PREFIX, "@{[PREFIX]}/CPAN";

use AnyEvent::MQTT;

my $mainLoop = AnyEvent->condvar;
my $jsonCodec = JSON::XS->new->canonical();
#FIXME: config file!
#FIXME: on_error callback
my $mqtt = AnyEvent::MQTT->new( 
	host => $configHash->{mqtt}->{server},
	user_name => $configHash->{mqtt}->{username}, password => $configHash->{mqtt}->{password},
	keep_alive_timer => 1,
	on_error => sub { die "horribly" } );
$mqtt->connect() or die;
# note we don't read MQTT messages, so no reason to subscribe

print $jsonCodec->pretty->encode(\%units);

sub decorateTree($$) {
	my ($hostname, $tree) = @_;
	my $numInputs = scalar(@{$tree->{inputs}});
	my $configInputs = $units{$hostname}->{config}->{inputs};
	#for(my $idx = $numInputs - 1; $idx > 0; --$idx) {
		# Potential bug if config.txt's input channels don't line up with status
		# this is only interesting in that status and config.txt have a channel# attribute!
	#	$tree->{inputs}->[$idx]->{name} = $configInputs->[$idx]->{name}
	#}
	foreach my $leaf (@{$tree->{inputs}}) {
		my $channel = $leaf->{channel};
		$leaf->{name} = $configInputs->[$channel]->{name};
	}
}

sub getInputName($$) {
	my ($hostname, $leaf) = @_;
	my $channel = $leaf->{channel};
	return $units{$hostname}{config}{inputs}[$channel]{name};
}
sub getInputType($$) {
	my ($hostname, $leaf) = @_;
	my $channel = $leaf->{channel};
	return $units{$hostname}{config}{inputs}[$channel]{type};
}
sub isInputDoubled($$) {
	my ($hostname, $leaf) = @_;
	my $channel = $leaf->{channel};
	return 0 unless exists $units{$hostname}{config}{inputs}[$channel]{double};
	return $units{$hostname}{config}{inputs}[$channel]{double};
}

#FIXME: move this up
my %HAunits = ( # Unit, Device Class, precision
	Pf    => ['%', 'power_factor', 2],
	Watts => ['W', 'power'],
	Vrms  => ['V', 'voltage', 3],
	Hz    => ['Hz', 'frequency', 5],
	Amps  => ['A', 'current', 3],
);
my %fieldBlacklist = (
	channel => 1, reversed => 1, phase => 1, lastphase => 1
);

sub processInputs {
	my ($hostname, $IWname, $inputs, $discoveryMQTT) = @_;

	my $vRMS;
	foreach my $input (@$inputs) {
		my $channel = $input->{channel};
		my $name = getInputName($hostname, $input);
		my $baseTopic = "iotawatt/$IWname/inputs/$name";
		
		my $payload = {};
		foreach my $key (keys %$input) {
			my $topic = "$baseTopic/$key";
			if(!$fieldBlacklist{$key}) {
				my $cmpName = "${IWname}_${name}_${key}";
				my $component = { name => "${name}_${key}", state_topic => $baseTopic, platform => 'sensor' };
				$component->{unique_id} = "iotawatt_${IWname}_${cmpName}";
				$component->{value_template} = "{{ value_json.$key }}";
				if(my $unit = $HAunits{$key}) {
					$component->{unit_of_measurement} = $unit->[0];
					$component->{device_class} = $unit->[1];
					$component->{state_class} = 'measurement';
					if(exists($unit->[2])) {
						$component->{suggested_display_precision} = $unit->[2];
					}
				}
				$discoveryMQTT->{components}->{$cmpName} = $component;
			}
			$payload->{$key} = $input->{$key} + 0;
		}
		my $inputType = getInputType($hostname, $input);
		if($inputType eq 'VT') {
			$vRMS = $input->{Vrms};
		} elsif($inputType eq 'CT') {
			$payload->{Pf} *= 100; # fractional to percentage
			my $amps;
			#FIXME: do we even need this? it doesn't get stored in the DB
			if( $input->{Pf} == 0 ) {
				$amps = 0;
			} else {
				my $double = isInputDoubled($hostname, $input) ? 2 : 1;
				$amps = $input->{Watts}/($input->{Pf}*($vRMS*$double));
			}
			$payload->{Amps} = $amps;
			my $cmpName = "${IWname}_${name}_Amps";
			my $component = { name => "${name}_Amps", state_topic => $baseTopic, platform => 'sensor' };
			$component->{unique_id} = "iotawatt_${IWname}_${cmpName}";
			$component->{value_template} = "{{ value_json.Amps }}";
			if(my $unit = $HAunits{Amps}) {
				$component->{unit_of_measurement} = $unit->[0];
				$component->{device_class} = $unit->[1];
				$component->{state_class} = 'measurement';
				if(exists($unit->[2])) {
					$component->{suggested_display_precision} = $unit->[2];
				}
			}

			$discoveryMQTT->{components}->{$cmpName} = $component;
		}
		$mqtt->publish( topic => $baseTopic, message => $jsonCodec->encode($payload) );
	}
}
sub generateMQTT($$) {
	my ($hostname, $tree) = @_;
	my $IWname = $units{$hostname}->{config}->{device}->{name};
	foreach my $type (qw( stats wifi influx1 influx2 emoncms pvoutput )) {
	#FIXME: just exclude inputs, outputs & datalogs? they're ARRAY not HASH
		next unless ref $tree->{$type};
		my $baseTopic = "iotawatt/$IWname/$type";
		foreach my $key (keys %{$tree->{$type}}) {
			my $topic = "$baseTopic/$key";
			$mqtt->publish( topic => $topic, message => $tree->{$type}->{$key} );
		}
	}
	my $inputs = $tree->{inputs};
	my $discoveryTopic = "homeassistant/device/iotawatt_${IWname}/config";
	my $discoveryPayload = { device => {name => "IoTaWatt $IWname", identifiers => ["iwatt_$IWname"] } };
	$discoveryPayload->{origin} = { name => 'iwMQTT' };
	$discoveryPayload->{components} = {};

	processInputs($hostname, $IWname, $inputs, $discoveryPayload);

	#print $jsonCodec->pretty->encode($discoveryPayload); exit;
	if($discoveryTopicsMQTT{$discoveryTopic}++ == 0) { #yes, this is post-increment on purpose
		$mqtt->publish( topic => $discoveryTopic, message => $jsonCodec->encode($discoveryPayload) );
	}
}

sub __get_unit_config {
	my ($hostname, $body, $hdr) = @_;
	my $tree = $jsonCodec->decode($body);
	$units{$hostname} = { config => $tree };
	#print $jsonCodec->pretty->encode( $units{$hostname} );
	$units{$hostname}->{timer} = AnyEvent->timer(interval => $updateInterval, cb => sub { fetch_status($hostname) } );
}

sub get_unit_config {
	my ($hostname) = @_;
	my $URL = "http://$hostname/$IWconfigURI";
	http_get $URL, on_body => sub { __get_unit_config($hostname, @_) };
}

sub __fetch_status {
	my ($hostname, $body, $hdr) = @_;
	print "hi $hostname: $hdr->{Status}\n";
	return unless $hdr->{Status} == 200; #hopefully errors are temporary
	my $tree = $jsonCodec->decode($body);
	#decorateTree($hostname, $tree);
	generateMQTT($hostname, $tree);
}
sub fetch_status {
	my ($hostname) = @_;
	my $URL = "http://$hostname/$baseURI";
	http_get $URL, on_body => sub { __fetch_status($hostname, @_) };
}

foreach my $key (keys %units) {
	# FIXME: re-fetch this periodically
	get_unit_config($key);
}

$mainLoop->recv;
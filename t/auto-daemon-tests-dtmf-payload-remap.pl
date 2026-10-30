#!/usr/bin/perl

use strict;
use warnings;
use NGCP::Rtpengine::Test;
use NGCP::Rtpclient::SRTP;
use NGCP::Rtpengine::AutoTest;
use Test::More;

# These are integration tests against the daemon, not a model of its codec store.
autotest_start(qw(--config-file=none -t -1 -i 203.0.113.1
	-n 2223 -f -L 7 -E)) or die;

sub sdp {
	my ($port, @codecs) = @_;
	my $s = "v=0\r\no=- 1 1 IN IP4 198.51.100.1\r\ns=remap\r\nt=0 0\r\n"
		. "m=audio $port RTP/AVP " . join(' ', map { $_->[0] } @codecs)
		. "\r\nc=IN IP4 198.51.100.1\r\n";
	for my $c (@codecs) {
		$s .= "a=rtpmap:$c->[0] $c->[1]\r\n";
		$s .= "a=fmtp:$c->[0] 0-16\r\n" if $c->[1] =~ /^telephone-event\//;
	}
	return $s . "a=sendrecv\r\n";
}

sub send_offer {
	my ($name, $codecs, $options) = @_;
	return rtpe_req('offer', $name, {
		'from-tag' => ft(), sdp => sdp(4000, @$codecs),
		'audio-player' => 'off', %{$options // {}},
	});
}

sub check_codecs {
	my ($name, $sdp, @codecs) = @_;
	my $pts = join(' ', map { $_->[0] } @codecs);
	like($sdp, qr/^m=audio \d+ RTP\/AVP \Q$pts\E\r?$/m, "$name: m-line PTs and order");
	for my $c (@codecs) {
		like($sdp, qr/^a=rtpmap:\Q$c->[0] $c->[1]\E\r?$/m, "$name: rtpmap $c->[0]");
		if ($c->[1] =~ /^telephone-event\//) {
			like($sdp, qr/^a=fmtp:\Q$c->[0]\E 0-16\r?$/m, "$name: fmtp follows event PT");
		}
	}
}

for my $pair ([96, 101], [101, 96], [96, 96]) {
	my ($original, $mapped) = @$pair;
	my $name = "telephone-event $original -> $mapped";
	my ($a, $b) = new_call([qw(198.51.100.1 4000)], [qw(198.51.100.1 4002)]);
	my $offer = send_offer($name, [[0, 'PCMU/8000'], [$original, 'telephone-event/8000']],
		{codec => {'telephone-event-payload' => $mapped}});
	check_codecs("$name offer", $offer->{sdp}, [0, 'PCMU/8000'], [$mapped, 'telephone-event/8000']);
	my ($port_b) = $offer->{sdp} =~ /m=audio (\d+)/;
	my $answer = rtpe_req('answer', $name, {
		'from-tag' => ft(), 'to-tag' => tt(), 'audio-player' => 'off',
		sdp => sdp(4002, [0, 'PCMU/8000'], [$mapped, 'telephone-event/8000']),
	});
	check_codecs("$name answer", $answer->{sdp}, [0, 'PCMU/8000'], [$original, 'telephone-event/8000']);
	my ($port_a) = $answer->{sdp} =~ /m=audio (\d+)/;

	# Existing DTMF forwarding can substitute SSRCs. Do not incorrectly demand
	# byte-for-byte RTP identity: assert PT, marker, sequence, timestamp and payload.
	for my $direction ([$a, $port_a, $b, $port_b, $original, $mapped],
			[$b, $port_b, $a, $port_a, $mapped, $original]) {
		my ($src, $in_port, $dst, $out_port, $in_pt, $out_pt) = @$direction;
		my $seq = 1000;
		my $audio = join('', map { chr($_) } 0..159);
		snd($src, $in_port, rtp(0, $seq++, 10000, 0x12345678, $audio));
		rcv($dst, $out_port, rtpm(0, 1000, 10000, -1, $audio));
		my @events = ([0x80, 7, 160], [0, 7, 320], [0, 135, 480], [0, 135, 480], [0, 135, 480]);
		for my $event (@events) {
			my ($marker, $flags, $duration) = @$event;
			my $payload = pack('CCn', 5, $flags, $duration);
			snd($src, $in_port, rtp($in_pt | $marker, $seq, 10160, 0x12345678, $payload));
			rcv($dst, $out_port, rtpm($out_pt | $marker, $seq, 10160, -1, $payload));
			$seq++;
		}
		snd($src, $in_port, rtp(0, $seq, 10640, 0x12345678, $audio));
		rcv($dst, $out_port, rtpm(0, $seq, 10640, -1, $audio));
	}
}

# Guard cases leave the offer unchanged, rather than taking over another codec's PT.
for my $case (
	['absent option', [[0, 'PCMU/8000'], [96, 'telephone-event/8000']], {}],
	['occupied PT', [[0, 'PCMU/8000'], [101, 'opus/48000/2'], [96, 'telephone-event/8000']],
		{codec => {'telephone-event-payload' => 101}}],
	['no events', [[0, 'PCMU/8000']], {codec => {'telephone-event-payload' => 101}}],
	['multiple event rates', [[0, 'PCMU/8000'], [96, 'telephone-event/8000'], [97, 'telephone-event/16000']],
		{codec => {'telephone-event-payload' => 101}}],
	['asymmetric codecs', [[0, 'PCMU/8000'], [96, 'telephone-event/8000']],
		{codec => {'telephone-event-payload' => 101}, flags => ['allow-asymmetric-codecs']}],
) {
	my ($name, $codecs, $options) = @$case;
	new_call;
	my $resp = send_offer($name, $codecs, $options);
	check_codecs($name, $resp->{sdp}, @$codecs);
}

new_call;
my $resp = send_offer('supplemental order', [[0, 'PCMU/8000'], [96, 'telephone-event/8000'], [13, 'CN/8000']],
	{codec => {'telephone-event-payload' => 101}});
check_codecs('supplemental order', $resp->{sdp}, [0, 'PCMU/8000'], [101, 'telephone-event/8000'], [13, 'CN/8000']);

new_call;
send_offer('event rejected in answer', [[0, 'PCMU/8000'], [96, 'telephone-event/8000']],
	{codec => {'telephone-event-payload' => 101}});
$resp = rtpe_req('answer', 'event rejected in answer', {
	'from-tag' => ft(), 'to-tag' => tt(), 'audio-player' => 'off', sdp => sdp(4002, [0, 'PCMU/8000']),
});
check_codecs('event rejected in answer', $resp->{sdp}, [0, 'PCMU/8000']);
unlike($resp->{sdp}, qr/telephone-event/, 'answer does not reintroduce rejected event codec');

# Re-offers must rebuild from the received SDP, not retain a stale remap.
new_call;
my $established = 0;
for my $stage (['initial remap', 101, 1], ['remove remap', 96, 0], ['reapply remap', 101, 1]) {
	my ($name, $out_pt, $enabled) = @$stage;
	my %options;
	$options{'to-tag'} = tt() if $established;
	$options{codec} = {'telephone-event-payload' => 101} if $enabled;
	my $off = send_offer("same-dialogue $name", [[0, 'PCMU/8000'], [96, 'telephone-event/8000']],
		\%options);
	check_codecs("same-dialogue $name offer", $off->{sdp}, [0, 'PCMU/8000'], [$out_pt, 'telephone-event/8000']);
	my $ans = rtpe_req('answer', "same-dialogue $name", {
		'from-tag' => ft(), 'to-tag' => tt(), 'audio-player' => 'off',
		sdp => sdp(4002, [0, 'PCMU/8000'], [$out_pt, 'telephone-event/8000']),
	});
	check_codecs("same-dialogue $name answer", $ans->{sdp}, [0, 'PCMU/8000'], [96, 'telephone-event/8000']);
	$established = 1;
}

# The former answerer can become offerer without exchanging the legs' PTs.
reverse_tags();
$resp = send_offer('reverse-leg reoffer', [[0, 'PCMU/8000'], [101, 'telephone-event/8000']], {
	'to-tag' => tt(), codec => {'telephone-event-payload' => 96},
});
check_codecs('reverse-leg reoffer', $resp->{sdp}, [0, 'PCMU/8000'], [96, 'telephone-event/8000']);
$resp = rtpe_req('answer', 'reverse-leg reanswer', {
	'from-tag' => ft(), 'to-tag' => tt(), 'audio-player' => 'off',
	sdp => sdp(4002, [0, 'PCMU/8000'], [96, 'telephone-event/8000']),
});
check_codecs('reverse-leg reanswer', $resp->{sdp}, [0, 'PCMU/8000'], [101, 'telephone-event/8000']);

new_call;
send_offer('answer option rejected', [[0, 'PCMU/8000'], [96, 'telephone-event/8000']], {});
$resp = rtpe_raw_req({
	command => 'answer', 'call-id' => cid(), 'from-tag' => ft(), 'to-tag' => tt(),
	sdp => sdp(4002, [0, 'PCMU/8000'], [96, 'telephone-event/8000']),
	codec => {'telephone-event-payload' => 101},
});
like($resp, qr/^error:/, 'valid remap PT is not accepted on an answer');
like($resp, qr/telephone-event-payload is only supported in offers/,
	'answer option error explains offer-only scope');

for my $bad (-1, 0, 95, 128, 'not-an-integer', [], {}) {
	new_call;
	my $resp = rtpe_raw_req({
		command => 'offer', 'call-id' => cid(), 'from-tag' => ft(),
		sdp => sdp(4000, [0, 'PCMU/8000'], [96, 'telephone-event/8000']),
		codec => {'telephone-event-payload' => $bad},
	});
	like($resp, qr/^error:/, 'invalid remap PT rejected');
	like($resp, qr/telephone-event-payload must be an integer from 96 to 127/,
		'invalid remap PT has actionable error');
}

# mr26's dictionary callbacks return void: reject before delete can mutate a call.
new_call;
send_offer('delete option rejected', [[0, 'PCMU/8000'], [96, 'telephone-event/8000']], {});
$resp = rtpe_raw_req({
	command => 'delete', 'call-id' => cid(),
	codec => {'telephone-event-payload' => 101},
});
like($resp, qr/^error:/, 'offer-only option rejects delete');
like($resp, qr/telephone-event-payload is only supported in offers/,
	'delete propagates callback error');
$resp = rtpe_raw_req({command => 'query', 'call-id' => cid()});
is($resp->{result}, 'ok', 'rejected delete leaves established call intact');

done_testing();

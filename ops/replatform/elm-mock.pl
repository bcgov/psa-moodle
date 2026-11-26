#!/usr/bin/perl
# ELM mock for Pass B (runbook §14.9, DR06; docs/passb-run-2.md M1). Stands in for ELM's API so a rehearsal copy never
# talks to the real one. Runs in the ops image (Perl, no other dependencies); one request at a time.
#   GET  anything  -> 200 {"value":[]}: local_psaelmsync's enrolment sync sees no records and no next page
#   POST anything  -> recorded FIRST (one line in /data/received.tsv: UTC time, path, body), then 200
#   /data/hold     -> if present when a POST arrives: the POST is recorded, the file removed, and the reply held for
#                     HOLD_SECONDS (default 300). Kill the sending php pod meanwhile: received here, never logged there.
# The bodies are personal data (completions): they stay on the mock's own volume; its log prints counts only.
use strict;
use warnings;
use IO::Socket::INET;
use POSIX qw(strftime);

$| = 1;
my $port = $ENV{PORT} || 8080;
my $hold = $ENV{HOLD_SECONDS} || 300;
my $srv = IO::Socket::INET->new(LocalPort => $port, Listen => 16, ReuseAddr => 1, Proto => 'tcp')
    or die "elm-mock: cannot listen on $port: $!\n";
my ($gets, $posts) = (0, 0);
print "elm-mock listening on $port\n";

while (my $c = $srv->accept) {
    $c->autoflush(1);
    my $line = <$c>;
    if (!defined $line) { close $c; next; }
    my ($method, $path) = $line =~ /^(\S+)\s+(\S+)/;
    $method //= ''; $path //= '';
    my %h;
    while (my $l = <$c>) {
        $l =~ s/\r?\n$//;
        last if $l eq '';
        my ($k, $v) = split /:\s*/, $l, 2;
        $h{lc $k} = $v if defined $v;
    }
    my $body = '';
    read($c, $body, $h{'content-length'}) if $h{'content-length'};
    my $resp;
    if ($method eq 'POST') {
        $posts++;
        (my $flat = $body) =~ s/[\r\n\t]+/ /g;
        (my $p = $path) =~ s/\?.*//;
        open(my $f, '>>', '/data/received.tsv') or die "elm-mock: /data/received.tsv: $!\n";
        print $f strftime('%Y-%m-%dT%H:%M:%SZ', gmtime), "\t$p\t$flat\n";
        close $f;
        print "POST #$posts recorded\n";
        if (-e '/data/hold') {
            unlink '/data/hold';
            print "POST #$posts: holding the reply for $hold s\n";
            sleep $hold;
        }
        $resp = '{"status":"received"}';
    } else {
        $gets++;
        print "GET #$gets answered with no records\n";
        $resp = '{"value":[]}';
    }
    print $c "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " . length($resp)
        . "\r\nConnection: close\r\n\r\n$resp";
    close $c;
}

#!/usr/bin/perl

# Regression test: a literal header field that follows an in-block stream
# reset must be skipped without closing the whole HTTP/2 connection.

# Before the fix, ngx_http_v2_state_process_header() computed the name
# length of a skipped field from stale field_start/field_end pointers; when
# they were equal, the field was rejected as "zero header name length" and
# the connection was closed with GOAWAY(PROTOCOL_ERROR).

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP2;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http http_v2 rewrite/)->plan(6)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    http2 on;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location / {
            return 200;
        }
    }
}

EOF

$t->run();

###############################################################################

# stream 1: only indexed fields precede an invalid pseudo-header
# (":status" in a request), which resets the stream; the next field is a
# literal with a new name, so it is skipped

my $s = Test::Nginx::HTTP2->new();
my $sid = $s->new_stream({ headers => [
	{ name => ':method', value => 'GET', mode => 0 },
	{ name => ':scheme', value => 'http', mode => 0 },
	{ name => ':path', value => '/', mode => 0 },
	{ name => ':status', value => '200', mode => 0 },
	{ name => 'x-after', value => 'v', mode => 4 }]});
my $frames = $s->read(all => [{ type => 'GOAWAY' }], wait => 0.5);

my ($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{':status'}, 400, 'invalid request rejected');

($frame) = grep { $_->{type} eq "GOAWAY" } @$frames;
is($frame, undef, 'no GOAWAY after skipped field');

# the connection is still usable

$sid = $s->new_stream({ path => '/' });
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
is($frame->{headers}->{':status'}, 200, 'next stream on same connection');

($frame) = grep { $_->{type} eq "GOAWAY" } @$frames;
is($frame, undef, 'connection not closed');

# a skipped field with an empty name is still a connection error;
# this guards the zero name length check kept by the fix

$s = Test::Nginx::HTTP2->new();
$sid = $s->new_stream({ headers => [
	{ name => ':method', value => 'GET', mode => 0 },
	{ name => ':scheme', value => 'http', mode => 0 },
	{ name => ':path', value => '/', mode => 0 },
	{ name => ':status', value => '200', mode => 0 },
	{ name => '', value => 'v', mode => 4 }]});
$frames = $s->read(all => [{ type => 'GOAWAY' }]);

($frame) = grep { $_->{type} eq "GOAWAY" } @$frames;
ok($frame, 'empty name in skipped field - GOAWAY');
is($frame && $frame->{code}, 1, 'empty name in skipped field - PROTOCOL_ERROR');

###############################################################################

#!/usr/bin/perl

# Regression test: HTTP/2 request trailers (nginx/nginx#1955).

# A client may end a request body with a trailer section: a HEADERS
# frame with END_STREAM on the open stream (RFC 9113, 8.1).  Before the
# fix, any HEADERS frame on a stream identifier not above the last one
# was a connection error: nginx sent GOAWAY with PROTOCOL_ERROR, and
# every request on the connection failed.  Now the trailer section is
# decoded, to keep the HPACK dynamic table in sync, and discarded, as
# for HTTP/1.1 chunked request bodies; it ends the request body.  A
# trailer section without END_STREAM, or with a pseudo-header, resets
# the stream only.  Trailers on a stream that nginx has already reset,
# or refused, are ignored, as the client sent them before it received
# RST_STREAM (RFC 9113, 5.1).  HEADERS on a stream that the client has
# already ended, that both sides have closed, or that was never opened
# are still a connection error.  After GOAWAY, HEADERS frames on open
# streams are processed: before, they were skipped, so the trailers on
# the last stream of a connection never ended its request body.  The
# header blocks of new streams after GOAWAY are decoded and ignored, to
# keep the HPACK table in sync for such trailers (RFC 9113, 6.8).

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

my $t = Test::Nginx->new()->has(qw/http http_v2 proxy rewrite/)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        http2 on;
        large_client_header_buffers 4 1k;

        location /proxy/ {
            add_header X-Body $request_body;
            proxy_pass http://127.0.0.1:8081/;
        }

        location /off/ {
            proxy_request_buffering off;
            proxy_pass http://127.0.0.1:8081/echo/;
        }

        location /early {
            return 200 "early";
        }

        location /hpack {
            add_header X-Trailer $http_x_trailer;
            return 200;
        }
    }

    server {
        listen       127.0.0.1:8082;
        server_name  localhost;

        http2 on;
        keepalive_requests 1;

        location /proxy/ {
            add_header X-Body $request_body;
            proxy_pass http://127.0.0.1:8081/;
        }
    }

    server {
        listen       127.0.0.1:8083;
        server_name  localhost;

        http2 on;
        http2_max_concurrent_streams 1;

        location /proxy/ {
            add_header X-Body $request_body;
            proxy_pass http://127.0.0.1:8081/;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        location /echo/ {
            add_header X-Body $request_body;
            proxy_pass http://127.0.0.1:8081/t.html;
        }
    }
}

EOF

$t->write_file('t.html', 'SEE-THIS');
$t->try_run('no http2')->plan(34);

###############################################################################

sub headers_of {
	my ($frames, $sid) = @_;
	my ($frame) = grep { $_->{type} eq 'HEADERS' && $_->{sid} == $sid }
		@$frames;
	return $frame ? $frame->{headers} : {};
}

sub frame {
	my ($type, $flags, $sid, $payload) = @_;
	return substr(pack('N', length $payload), 1)
		. pack('CCN', $type, $flags, $sid) . $payload;
}

sub trailer {
	my ($name, $value) = @_;
	return { name => $name, value => $value, mode => 2 };
}

sub hpack_request {
	my ($s, $value) = @_;

	# references the trailer field in the dynamic table

	my $sid = $s->new_stream({ headers => [
		{ name => ':method', value => 'GET', mode => 0 },
		{ name => ':scheme', value => 'http', mode => 0 },
		{ name => ':path', value => '/hpack', mode => 1 },
		{ name => ':authority', value => 'localhost', mode => 1 },
		{ name => 'x-trailer', value => $value, mode => 0 }]});

	return headers_of($s->read(all => [{ sid => $sid, fin => 1 }]), $sid);
}

# trailers end a buffered request body

my $s = Test::Nginx::HTTP2->new();
my $sid = $s->new_stream({ path => '/proxy/t.html', body_more => 1 });
$s->h2_body('TEST', { body_more => 1 });
$s->new_stream({ headers => [ trailer('x-trailer', 'one') ] }, $sid);
my $frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

is(headers_of($frames, $sid)->{':status'}, 200, 'trailers - status');
is(headers_of($frames, $sid)->{'x-body'}, 'TEST', 'trailers - body');
ok(!grep({ $_->{type} eq 'GOAWAY' } @$frames), 'trailers - no GOAWAY');

is(hpack_request($s, 'one')->{'x-trailer'}, 'one', 'trailers - hpack');

# with a content length

$s = Test::Nginx::HTTP2->new();
$sid = $s->new_stream({ path => '/proxy/t.html', body_more => 1,
	headers => [
		{ name => ':method', value => 'GET', mode => 0 },
		{ name => ':scheme', value => 'http', mode => 0 },
		{ name => ':path', value => '/proxy/t.html', mode => 1 },
		{ name => ':authority', value => 'localhost', mode => 1 },
		{ name => 'content-length', value => '4', mode => 1 }]});
$s->h2_body('TEST', { body_more => 1 });
$s->new_stream({ headers => [ trailer('x-trailer', 'two') ] }, $sid);
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

is(headers_of($frames, $sid)->{'x-body'}, 'TEST', 'content length - body');

# trailers before the declared length is received

$s = Test::Nginx::HTTP2->new();
$sid = $s->new_stream({ path => '/proxy/t.html', body_more => 1,
	headers => [
		{ name => ':method', value => 'GET', mode => 0 },
		{ name => ':scheme', value => 'http', mode => 0 },
		{ name => ':path', value => '/proxy/t.html', mode => 1 },
		{ name => ':authority', value => 'localhost', mode => 1 },
		{ name => 'content-length', value => '10', mode => 1 }]});
$s->h2_body('TEST', { body_more => 1 });
$s->new_stream({ headers => [ trailer('x-trailer', 'short') ] }, $sid);
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

is(headers_of($frames, $sid)->{':status'}, 400, 'short body - 400');

# unbuffered request body

$s = Test::Nginx::HTTP2->new();
$sid = $s->new_stream({ path => '/off/', body_more => 1 });
$s->h2_body('TEST', { body_more => 1 });
$s->new_stream({ headers => [ trailer('x-trailer', 'three') ] }, $sid);
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

is(headers_of($frames, $sid)->{':status'}, 200, 'unbuffered - status');
is(headers_of($frames, $sid)->{'x-body'}, 'TEST', 'unbuffered - body');

# unbuffered request body, trailers split across reads

$s = Test::Nginx::HTTP2->new();
$sid = $s->new_stream({ path => '/off/', body_more => 1 });
my $trailers = frame(0x1, 0x5, $sid,
	Test::Nginx::HTTP2::hpack($s, 'x-trailer', 'a' x 40, mode => 2));
$s->raw_write(frame(0x0, 0x0, $sid, 'x' x 10) . substr($trailers, 0, 12));
select undef, undef, undef, 0.3;
$s->raw_write(substr($trailers, 12));
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

is(headers_of($frames, $sid)->{':status'}, 200, 'unbuffered split - status');
is(headers_of($frames, $sid)->{'x-body'}, 'x' x 10, 'unbuffered split - body');

# an empty trailer section

$s = Test::Nginx::HTTP2->new();
$sid = $s->new_stream({ path => '/proxy/t.html', body_more => 1 });
$s->h2_body('TEST', { body_more => 1 });
$s->raw_write(frame(0x1, 0x5, $sid, ''));
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

is(headers_of($frames, $sid)->{'x-body'}, 'TEST', 'empty trailers - body');

# trailers without a body

$s = Test::Nginx::HTTP2->new();
$sid = $s->new_stream({ path => '/proxy/t.html', body_more => 1 });
$s->new_stream({ headers => [ trailer('x-trailer', 'four') ] }, $sid);
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

is(headers_of($frames, $sid)->{':status'}, 200, 'no body - status');

# trailers in HEADERS and CONTINUATION frames

$s = Test::Nginx::HTTP2->new();
$sid = $s->new_stream({ path => '/proxy/t.html', body_more => 1 });
$s->h2_body('TEST', { body_more => 1 });
$s->new_stream({ continuation => [ 5 ], headers => [
	trailer('x-trailer', 'five'), trailer('x-more', 'more') ] }, $sid);
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

is(headers_of($frames, $sid)->{'x-body'}, 'TEST', 'continuation - body');
is(hpack_request($s, 'five')->{'x-trailer'}, 'five',
	'continuation - hpack');

# trailers without END_STREAM reset the stream only

$s = Test::Nginx::HTTP2->new();
$sid = $s->new_stream({ path => '/proxy/t.html', body_more => 1 });
$s->h2_body('TEST', { body_more => 1 });
$s->new_stream({ body_more => 1,
	headers => [ trailer('x-trailer', 'six') ] }, $sid);
$frames = $s->read(all => [{ type => 'RST_STREAM' }]);

my ($frame) = grep { $_->{type} eq 'RST_STREAM' } @$frames;
is($frame->{sid}, $sid, 'no END_STREAM - RST_STREAM');
is($frame->{code}, 1, 'no END_STREAM - PROTOCOL_ERROR');
is(hpack_request($s, 'six')->{'x-trailer'}, 'six',
	'no END_STREAM - connection kept');

# a pseudo-header in trailers resets the stream only

$s = Test::Nginx::HTTP2->new();
$sid = $s->new_stream({ path => '/proxy/t.html', body_more => 1 });
$s->h2_body('TEST', { body_more => 1 });
$s->new_stream({ headers => [ trailer('x-trailer', 'seven'),
	{ name => ':path', value => '/', mode => 2 } ] }, $sid);
$frames = $s->read(all => [{ type => 'RST_STREAM' }]);

($frame) = grep { $_->{type} eq 'RST_STREAM' } @$frames;
is($frame->{sid}, $sid, 'pseudo-header - RST_STREAM');
is($frame->{code}, 1, 'pseudo-header - PROTOCOL_ERROR');
is(hpack_request($s, 'seven')->{'x-trailer'}, 'seven',
	'pseudo-header - connection kept');

# trailers on a stream that nginx answered early and reset

$s = Test::Nginx::HTTP2->new();
$sid = $s->new_stream({ path => '/early', body_more => 1 });
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
is(headers_of($frames, $sid)->{':status'}, 200, 'reset stream - response');

$s->h2_body('TEST', { body_more => 1 });
$s->new_stream({ headers => [ trailer('x-trailer', 'eight') ] }, $sid);
$frames = $s->read(all => [{ type => 'GOAWAY' }], wait => 0.5);

ok(!grep({ $_->{type} eq 'GOAWAY' } @$frames), 'reset stream - no GOAWAY');
is(hpack_request($s, 'eight')->{'x-trailer'}, 'eight',
	'reset stream - hpack');

# HEADERS on a stream closed by both sides: connection error

$s = Test::Nginx::HTTP2->new();
$sid = $s->new_stream({ path => '/early' });
$s->read(all => [{ sid => $sid, fin => 1 }]);
$s->new_stream({ headers => [ trailer('x-trailer', 'ten') ] }, $sid);
$frames = $s->read(all => [{ type => 'GOAWAY' }]);

($frame) = grep { $_->{type} eq 'GOAWAY' } @$frames;
is($frame->{code}, 1, 'closed by both sides - PROTOCOL_ERROR');

# HEADERS on a stream that was never opened: connection error

$s = Test::Nginx::HTTP2->new();
$sid = $s->new_stream({ path => '/early' }, 3);
$s->read(all => [{ sid => $sid, fin => 1 }]);
$s->new_stream({ headers => [ trailer('x-trailer', 'eleven') ] }, 1);
$frames = $s->read(all => [{ type => 'GOAWAY' }]);

($frame) = grep { $_->{type} eq 'GOAWAY' } @$frames;
is($frame->{code}, 1, 'never opened - PROTOCOL_ERROR');

# trailers on the last stream, after GOAWAY was sent

$s = Test::Nginx::HTTP2->new(port(8082));
$sid = $s->new_stream({ path => '/proxy/t.html', body_more => 1 });
$s->h2_body('TEST', { body_more => 1 });
$s->new_stream({ headers => [ trailer('x-trailer', 'last') ] }, $sid);
$frames = $s->read(all => [{ sid => $sid, fin => 1 }], wait => 3);

ok(grep({ $_->{type} eq 'GOAWAY' } @$frames), 'last stream - GOAWAY');
is(headers_of($frames, $sid)->{'x-body'}, 'TEST', 'last stream - body');

# after GOAWAY, the header blocks of new streams are still decoded,
# so that trailers on an open stream use the same HPACK table

$s = Test::Nginx::HTTP2->new(port(8082));
$sid = $s->new_stream({ path => '/proxy/t.html', body_more => 1 });
$s->h2_body('TEST', { body_more => 1 });
$s->new_stream({ headers => [
	{ name => ':method', value => 'GET', mode => 0 },
	{ name => ':scheme', value => 'http', mode => 0 },
	{ name => ':path', value => '/proxy/t.html', mode => 1 },
	{ name => ':authority', value => 'localhost', mode => 1 },
	trailer('x-trailer', 'skipped') ]});
$s->new_stream({ headers => [
	{ name => 'x-trailer', value => 'skipped', mode => 0 } ] }, $sid);
$frames = $s->read(all => [{ sid => $sid, fin => 1 }], wait => 3);

is(headers_of($frames, $sid)->{'x-body'}, 'TEST', 'after GOAWAY - hpack');

# after GOAWAY, a new stream's header block in HEADERS and CONTINUATION

$s = Test::Nginx::HTTP2->new(port(8082));
$sid = $s->new_stream({ path => '/proxy/t.html', body_more => 1 });
$s->h2_body('TEST', { body_more => 1 });
$s->new_stream({ path => '/proxy/t.html', continuation => [ 5 ] });
$s->new_stream({ headers => [ trailer('x-trailer', 'cont') ] }, $sid);
$frames = $s->read(all => [{ sid => $sid, fin => 1 }], wait => 3);

is(headers_of($frames, $sid)->{'x-body'}, 'TEST',
	'after GOAWAY - continuation');

# trailers on a stream that nginx refused

$s = Test::Nginx::HTTP2->new(port(8083));
$sid = $s->new_stream({ path => '/proxy/t.html', body_more => 1 });
my $sid2 = $s->new_stream({ path => '/proxy/t.html', body_more => 1 });
$s->new_stream({ headers => [ trailer('x-trailer', 'refused') ] }, $sid2);
$s->new_stream({ headers => [ trailer('x-trailer', 'first') ] }, $sid);
$frames = $s->read(all => [{ sid => $sid, fin => 1 }]);

($frame) = grep { $_->{type} eq 'RST_STREAM' } @$frames;
is($frame && $frame->{code}, 7, 'refused stream - REFUSED_STREAM');
is(headers_of($frames, $sid)->{':status'}, 200, 'refused stream - other');

# trailers over the header size limit

$s = Test::Nginx::HTTP2->new();
$sid = $s->new_stream({ path => '/proxy/t.html', body_more => 1 });
$s->new_stream({ headers => [ trailer('x-trailer', 'x' x 4100) ] }, $sid);
$frames = $s->read(all => [{ type => 'GOAWAY' }]);

($frame) = grep { $_->{type} eq 'GOAWAY' } @$frames;
is($frame->{code}, 11, 'too large - ENHANCE_YOUR_CALM');

# HEADERS on a stream already ended by the client: connection error

$s = Test::Nginx::HTTP2->new();
$s->h2_settings(0, 0x4 => 0);
$sid = $s->new_stream({ path => '/t.html' });
$s->read(all => [{ sid => $sid, type => 'HEADERS' }]);
$s->new_stream({ headers => [ trailer('x-trailer', 'nine') ] }, $sid);
$frames = $s->read(all => [{ type => 'GOAWAY' }]);

($frame) = grep { $_->{type} eq 'GOAWAY' } @$frames;
is($frame->{code}, 1, 'half-closed - PROTOCOL_ERROR');

$t->stop();

like($t->read_file('error.log'), qr/client sent invalid trailer: ":path"/,
	'invalid trailer logged');

###############################################################################

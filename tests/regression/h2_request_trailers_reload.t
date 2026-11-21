#!/usr/bin/perl

# Regression test: HTTP/2 request trailers after a reload (nginx/nginx#1955).

# On a graceful shutdown of a worker, for example on reload, nginx sends
# GOAWAY to HTTP/2 connections that have open streams and keeps serving
# those streams.  Before the fix, every HEADERS frame after GOAWAY was
# skipped, so the trailer section of a stream that was still receiving
# its request body was dropped, and the request waited for
# client_body_timeout.  Now the trailer section ends the request body.

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
        listen       127.0.0.1:8080 http2;
        server_name  localhost;

        client_body_timeout  10s;

        location / {
            proxy_pass http://127.0.0.1:8081;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        location / {
            return 200 "SEEN";
        }
    }
}

EOF

$t->try_run('no http2')->plan(3);

###############################################################################

my $s = Test::Nginx::HTTP2->new();
my $sid = $s->new_stream({ path => '/', body_more => 1 });
$s->h2_body('TEST', { body_more => 1 });

$t->reload();

my $frames = $s->read(all => [{ type => 'GOAWAY' }], wait => 3);
my ($goaway) = grep { $_->{type} eq 'GOAWAY' } @$frames;
ok($goaway, 'GOAWAY on reload');

$s->new_stream({ headers => [
	{ name => 'x-trailer', value => 'reload', mode => 2 } ] }, $sid);
$frames = $s->read(all => [{ sid => $sid, fin => 1 }], wait => 5);

my ($h) = grep { $_->{type} eq 'HEADERS' && $_->{sid} == $sid } @$frames;
is($h && $h->{headers}{':status'}, 200, 'trailers after reload - status');

($goaway) = grep { $_->{type} eq 'GOAWAY' && $_->{code} } @$frames;
ok(!$goaway, 'trailers after reload - no error GOAWAY');

undef $s;

###############################################################################

#!/usr/bin/perl

# Regression test: with "alias" in a regular expression location and
# variables in the access_log path, requests must be logged.

# In such a location, the alias is mapped to the whole path of the
# requested file, and ngx_http_map_uri_to_path() returns the length of
# this whole path as the root length.  Before the fix, the root test in
# ngx_http_log_script_write() tested the file path as a directory: the
# log entry of every response that the static module didn't send was
# dropped, with 'testing "..." existence failed' (ENOTDIR for an
# existing file, ENOENT for a missing one).  The directory of the
# aliased path is tested now, also when try_files "" maps the request
# to the alias itself.  Requests into a missing directory are still not
# logged.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http rewrite proxy/)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    log_format  short  '$uri $status';

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location ~ ^/static/(.*)$ {
            alias %%TESTDIR%%/html/$1;
            access_log %%TESTDIR%%/static_$status.log short;
        }

        location ~ ^/return/(.*)$ {
            alias %%TESTDIR%%/html/$1;
            access_log %%TESTDIR%%/return_$status.log short;
            return 200;
        }

        location ~ ^/fixed/ {
            alias %%TESTDIR%%/html/;
            access_log %%TESTDIR%%/fixed_$status.log short;
            return 200;
        }

        location ~ ^/tf/(.*)$ {
            alias %%TESTDIR%%/html/$1;
            try_files "" =404;
            access_log %%TESTDIR%%/tf_$status.log short;
            proxy_pass http://127.0.0.1:8081;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        location / {
            return 200;
        }
    }
}

EOF

mkdir($t->testdir() . '/html');
$t->write_file('html/file.html', 'SEE-THIS');

$t->try_run('no regex alias')->plan(9);

###############################################################################

like(http_get('/static/file.html'), qr/SEE-THIS/, 'file served');
http_get('/static/missing.html');
http_get('/static/nodir/missing.html');
http_get('/return/file.html');
http_get('/return/');
http_get('/fixed/file.html');
http_get('/tf/file.html');

$t->stop();

my $d = $t->testdir();

sub read_log {
	my ($file) = @_;
	open my $fh, '<', $file or return '';
	local $/;
	return <$fh>;
}

like(read_log("$d/static_200.log"), qr!^/static/file.html 200$!m,
	'static 200 logged');
like(read_log("$d/static_404.log"), qr!^/static/missing.html 404$!m,
	'static 404 logged');
unlike(read_log("$d/static_404.log"), qr/nodir/,
	'missing directory not logged');
like(read_log("$d/return_200.log"), qr!^/return/file.html 200$!m,
	'return on a file logged');
like(read_log("$d/return_200.log"), qr!^/return/ 200$!m,
	'return on the directory logged');
ok(-s "$d/fixed_200.log", 'alias without variables logged');
ok(grep({ -s } glob("$d/tf_*.log")), 'try_files with an empty file logged');

my $log = $t->read_file('error.log');
$log =~ s/^.*"\Q$d\E\/html\/nodir" existence failed.*\n//mg;

unlike($log, qr/existence failed/, 'root test errors only for nodir');

###############################################################################

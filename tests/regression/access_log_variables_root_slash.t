#!/usr/bin/perl

# Regression test: with "root /" and variables in the access_log path,
# requests must be logged.

# "root /" is stored as an empty string, so that the root and the URI
# can be concatenated.  Before the fix, the root test in
# ngx_http_log_script_write() tested this empty string instead of "/":
# with "disable_symlinks off", the default, the test failed with ENOENT,
# 'testing "" existence failed' was logged, and the log entry of every
# request that the static module didn't serve was dropped.  With
# "disable_symlinks on" or "if_not_owner", the worker's current directory
# was tested instead, which usually exists: the checks for these two
# modes pass before the fix too, and only guard the fixed path.

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

my $t = Test::Nginx->new()->has(qw/http rewrite/)
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

        root /;

        access_log %%TESTDIR%%/server_$status.log short;

        location /off/ {
            access_log %%TESTDIR%%/off_$status.log short;
            return 200;
        }

        location /on/ {
            disable_symlinks on;
            access_log %%TESTDIR%%/on_$status.log short;
            return 200;
        }

        location /owner/ {
            disable_symlinks if_not_owner;
            access_log %%TESTDIR%%/owner_$status.log short;
            return 200;
        }

        location /nonexistent-regress-dir/ {
            access_log %%TESTDIR%%/static_$status.log short;
        }
    }
}

EOF

$t->try_run('no disable_symlinks')->plan(6);

###############################################################################

http_get('/off/');
http_get('/on/');
http_get('/owner/');
http_get('/nonexistent-regress-dir/file');
http("BAD REQUEST\r\n\r\n");

$t->stop();

my $d = $t->testdir();

ok(-s "$d/off_200.log", 'return logged, disable_symlinks off');
ok(-s "$d/on_200.log", 'return logged, disable_symlinks on');
ok(-s "$d/owner_200.log", 'return logged, disable_symlinks if_not_owner');
ok(-s "$d/static_404.log", 'static 404 logged');
ok(-s "$d/server_400.log", 'bad request logged');

unlike($t->read_file('error.log'), qr/existence failed/, 'no root test errors');

###############################################################################

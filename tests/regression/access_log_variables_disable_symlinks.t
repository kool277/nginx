#!/usr/bin/perl

# Regression test: with variables in the access_log path and
# "disable_symlinks on", requests to multi-segment URIs must be logged.

# Before the fix, ngx_http_log_script_write() truncated the root test
# path only with '\0' and left path.len at the full "root + URI" length.
# With disable_symlinks, the path is walked component by component up to
# path.len, so the test opened a non-existent "root/URI" path, logged
# 'testing "..." existence failed' and silently dropped the log entry.

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

my $t = Test::Nginx->new()->has(qw/http/)
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

        root %%TESTDIR%%/html;

        disable_symlinks on;

        location / {
            access_log %%TESTDIR%%/$arg_log.log short;
            return 200;
        }
    }
}

EOF

mkdir($t->testdir() . '/html');

$t->try_run('no disable_symlinks')->plan(4);

###############################################################################

http_get('/one?log=a');
http_get('/one/two?log=a');
http_get('/one/two/?log=a');

$t->stop();

my $log = $t->read_file('a.log');

like($log, qr!^/one 200$!m, 'single segment logged');
like($log, qr!^/one/two 200$!m, 'two segments logged');
like($log, qr!^/one/two/ 200$!m, 'trailing slash logged');

unlike($t->read_file('error.log'), qr/existence failed/, 'no root test errors');

###############################################################################

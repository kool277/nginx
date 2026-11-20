#!/usr/bin/perl

# Regression test: "disable_symlinks on from=" with a trailing slash
# must not check the "from" directory itself for symbolic links.

# The "from" directory is trusted, and the path of a file inside it is
# only checked after it.  The directory itself, as tested without a
# trailing slash by the access_log root test and by the index module,
# is one byte shorter than a "from" value that ends with a slash.
# Before the fix, ngx_http_set_disable_symlinks() then checked the
# whole path, so a symbolic link above the root failed the test, while
# files under the root were served: requests with variables in the
# access_log path weren't logged, and the root directory without an
# index file returned 500 with a critical openat() error instead of 403.
# The fix applies only to such directory tests: a file named by "from"
# with a trailing slash is still checked, and so are symbolic links
# inside the "from" directory.

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

my $t = Test::Nginx->new()->has(qw/http rewrite symlink/)
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

        root %%TESTDIR%%/link/html;

        disable_symlinks on from=%%TESTDIR%%/link/html/;

        location / {
            access_log %%TESTDIR%%/static_$status.log short;
        }

        location /return/ {
            access_log %%TESTDIR%%/return_$status.log short;
            return 200;
        }

        location = /exact.html {
            root %%TESTDIR%%/real/html;
            disable_symlinks on from=%%TESTDIR%%/real/html/exact.html/;
        }
    }
}

EOF

my $d = $t->testdir();

mkdir("$d/real");
mkdir("$d/real/html");
$t->write_file('real/html/file.html', 'SEE-THIS');
symlink("$d/real", "$d/link") or die "Can't create symlink: $!\n";
symlink("$d/real/html/file.html", "$d/real/html/inlink.html")
	or die "Can't create symlink: $!\n";
symlink("$d/real/html/file.html", "$d/real/html/exact.html")
	or die "Can't create symlink: $!\n";

$t->try_run('no disable_symlinks')->plan(7);

###############################################################################

like(http_get('/file.html'), qr/SEE-THIS/, 'file under from served');
like(http_get('/'), qr/ 403 /, 'from directory without index');
like(http_get('/inlink.html'), qr/ 403 /, 'symlink inside from');
like(http_get('/exact.html'), qr/ 403 /, 'symlinked file named by from');

http_get('/return/');

$t->stop();

ok(-s "$d/return_200.log", 'return logged');
ok(-s "$d/static_403.log", 'directory without index logged');

unlike($t->read_file('error.log'), qr/existence failed|\[crit\]/,
	'no root test errors');

###############################################################################

#!/usr/bin/perl

# Regression test: IPv6 text forms parsed by ngx_inet6_addr().

# Before the fix, "1:2:3:4:5:6:7::" and an IPv4 tail of "255.255.255.255"
# were rejected, while a single leading ":" (":1::") and a trailing ":"
# after "::" ("1::2:") were accepted.  The parser is shared by "listen",
# "allow"/"deny", "set_real_ip_from", "geo" and the realip module; realip
# is used here to observe the result.

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

my $t = Test::Nginx->new()->has(qw/http realip/);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        set_real_ip_from  127.0.0.1/32;
        real_ip_header    X-Real-IP;

        location / {
            add_header X-IP $remote_addr always;
            return 204;
        }
    }
}

EOF

$t->try_run('no realip')->plan(9);

###############################################################################

# valid forms

is(ip('1:2:3:4:5:6:7::'), '1:2:3:4:5:6:7:0', 'seven groups and trailing ::');
is(ip('::ffff:255.255.255.255'), '::ffff:255.255.255.255',
	'IPv4 tail 255.255.255.255');
is(ip('1:2:3:4:5:6:255.255.255.255'), '1:2:3:4:5:6:ffff:ffff',
	'six groups and IPv4 tail 255.255.255.255');
is(ip('::1'), '::1', 'loopback still parsed');

# malformed forms are ignored, so the connection address is kept

is(ip(':1::'), '127.0.0.1', 'single leading colon');
is(ip(':1:2:3:4:5:6:7:8'), '127.0.0.1', 'single leading colon, 8 groups');
is(ip('1::2:'), '127.0.0.1', 'trailing colon after ::');
is(ip('::1:'), '127.0.0.1', 'trailing colon after :: and one group');
is(ip('1:2:3:4:5:6::255.255.255.255'), '127.0.0.1',
	'too many groups with IPv4 tail 255.255.255.255');

###############################################################################

sub ip {
	my ($addr) = @_;
	my $r = http(<<EOF);
GET / HTTP/1.0
Host: localhost
X-Real-IP: $addr

EOF
	return $r =~ /^X-IP: (.*?)\x0d?$/m ? $1 : undef;
}

###############################################################################

# Regression tests

Each `.t` file here reproduces one bug fixed on this branch. The tests
follow the conventions of [nginx-tests](https://github.com/nginx/nginx-tests).
Tests of runtime behaviour use its `Test::Nginx` library, which is not part
of this repository, and need a built nginx binary. Tests of the build
system, such as `configure_builddir_suffix.t`, need neither.

## Running

Build nginx, then point the tests at the binary and at the `lib/`
directory of an nginx-tests checkout:

```sh
git clone https://github.com/nginx/nginx-tests.git /path/to/nginx-tests

auto/configure --with-debug ... && make

TEST_NGINX_BINARY=$PWD/objs/nginx \
    prove -I /path/to/nginx-tests/lib tests/regression/
```

Run a single test with `prove -v`:

```sh
TEST_NGINX_BINARY=$PWD/objs/nginx \
    prove -v -I /path/to/nginx-tests/lib tests/regression/configure_builddir_suffix.t
```

The environment variables understood by nginx-tests (`TEST_NGINX_VERBOSE`,
`TEST_NGINX_LEAVE`, `TEST_NGINX_CATLOG` and others) work here too.

A test skips itself when the binary lacks a module it needs.

## Tests

| Test | What it checks |
|---|---|
| `configure_builddir_suffix.t` | `auto/configure` generates valid object paths when `--builddir` contains `.c` or `.S`. Needs `make` and a C compiler; does not use `TEST_NGINX_BINARY` or `Test::Nginx`. Run it with `prove tests/regression/configure_builddir_suffix.t`. |
| `h2_reset_stream_skipped_field.t` | A literal header field after an in-block HTTP/2 stream reset is skipped without closing the connection (nginx/nginx#1977). Needs the `http_v2` and `rewrite` modules. |
| `inet6_addr_parse.t` | IPv6 text forms accepted and rejected by `ngx_inet6_addr()`, observed through realip (nginx/nginx#1915). Needs the `realip` module. |
| `access_log_variables_disable_symlinks.t` | Requests are logged when the `access_log` path has variables and `disable_symlinks` is on (nginx/nginx#1900). |
| `access_log_variables_root_slash.t` | Requests are logged when the `access_log` path has variables and the root is `/`, which is stored as an empty string. With `disable_symlinks off`, the default, every request that the static module didn't serve was dropped. Needs the `rewrite` module. |
| `disable_symlinks_from_trailing_slash.t` | `disable_symlinks on from=` with a trailing slash doesn't check the `from` directory itself when it's tested as a directory (the `access_log` root test, a directory without an index file), while symbolic links inside it and a file named by `from` are still refused. Needs the `rewrite` module and symbolic links. |

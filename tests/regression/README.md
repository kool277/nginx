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

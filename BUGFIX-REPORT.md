# Bug fix report: branch `claude/bugfixes-and-docs`

This report covers a bug hunt in nginx 1.31.9 (fork `kool277/nginx`), done
on 2026-11-14 on one Linux x86-64 host. It reports coverage, not
completeness: it lists what was searched, what was found, and what was not
covered.

## Branch state

| | |
|---|---|
| Branch | `claude/bugfixes-and-docs`, from `master` at `2a3a19c6f` |
| Head | the commit that adds this report (the last code commit is `4c3b64353`) |
| Compared with `upstream/master` (nginx/nginx) | 8 ahead, including this report; 0 behind. The fork's `master` was level with upstream when the work started. |

## Bugs fixed

| Area | Symptom | Root cause | Commits | How verified |
|---|---|---|---|---|
| Configure (`auto/make`) | `make` fails with "No rule to make target" when `--builddir` contains `.c`, `.cc`, `.cpp` or `.S` (for example `objs.clang`, or a Debian CI temp dir with `.S`). Upstream issue nginx/nginx#1779. | The sed substitutions that turn source paths into object paths weren't anchored, so later expressions matched the build directory inside paths that were already translated. | `529c94dad` (cherry-pick of open upstream PR nginx/nginx#1780, author kept), `f5bbcc9f5` (test) | `tests/regression/configure_builddir_suffix.t`: 4/4 fail before, 4/4 pass after. The independent review found the default `objs` Makefile byte-identical before and after, and checked win32 and POSIX sh/BSD sed. Found while building this branch with clang into `objs.clang`. |
| HTTP/2 | A request whose header block resets the stream (for example `:status` in a request), followed by a literal header field, closed the whole connection with GOAWAY(PROTOCOL_ERROR), "client sent zero header name length", so every stream on it was lost. Upstream issue nginx/nginx#1977 (no upstream fix). | `ngx_http_v2_state_field_skip()` doesn't set `field_start`/`field_end`, but `ngx_http_v2_state_process_header()` computed the skipped field's lengths from those stale pointers. The same stale lengths were charged against the header list limit. | `7b185de7a` (own fix + test) | `tests/regression/h2_reset_stream_skipped_field.t` fails before (2 of 6 checks) and passes after. The first review found a regression in the first version of the fix (a mid-field `client_header_timeout`), which was fixed before commit. The reviewer's 11 edge cases pass: timeouts mid-field, refused streams, a CONTINUATION flood (now ENHANCE_YOUR_CALM, bounded), split reads, Huffman fields. All nginx-tests `h2*.t` pass. |
| Core (`ngx_inet6_addr`) | `1:2:3:4:5:6:7::` and an IPv4 tail of `255.255.255.255` were rejected (`listen`, `allow`, `set_real_ip_from`, `geo`, realip), while `:1::` and `1::2:` were accepted. Upstream issue nginx/nginx#1915. | Trailing `::` after 7 groups failed the final group count; `ngx_inet_addr()` returns `INADDR_NONE` for 255.255.255.255; a single leading or trailing `:` wasn't checked. | `66f2ad789` (cherry-pick of open upstream PR nginx/nginx#1918, author kept), `f2c95042f` (test) | `tests/regression/inet6_addr_parse.t`: 6/9 fail before, all pass after. The independent review compared the parser with glibc `inet_pton()` on about 21 million generated inputs under ASan and UBSan. Every input whose result changed now agrees with `inet_pton()`. There were no sanitizer reports. |
| Log (`access_log`) | With variables in the `access_log` path and `disable_symlinks on`/`if_not_owner`, requests to multi-segment URIs weren't logged, and the error log said `testing "..." existence failed`. Upstream issue nginx/nginx#1900. | The root test truncated the path with `'\0'` but left `path.len` at root + URI. `ngx_open_file_wrapper()` walks by length, so it opened `root/URI`. | `e577a461d` (cherry-pick of open upstream PR nginx/nginx#1903, author kept), `4c3b64353` (test) | `tests/regression/access_log_variables_disable_symlinks.t`: 3/4 fail before, all pass after. The independent review checked `on`, `if_not_owner`, `from=`, alias, `$var` roots and symlinked roots (still rejected), and ran `access_log*.t` and `http_disable_symlinks.t`. |

Every fix was also built warning-free with gcc 13.3 and clang 19.1.7. nginx builds with `-Werror`, and clang adds `-Wextra -Wconditional-uninitialized`. The full nginx-tests suite was run on the normal build and on the ASan+UBSan build (see [Test results](#test-results)).

Run the regression tests with:

```sh
TEST_NGINX_BINARY=$PWD/objs/nginx prove -I /path/to/nginx-tests/lib tests/regression/
```

See `tests/regression/README.md` for details.

## Test results

The suite was nginx-tests at `c0b7894`: 512 test files. Runs used `prove -j8` (`-j6` for ASan), niced.

| Build | Before (fork `master`) | After (branch head) |
|---|---|---|
| gcc 13.3, `--with-debug`, all modules listed in [Not covered](#not-covered) as enabled | PASS: 7121 tests, 38 files skipped | PASS: 7121 tests, 38 files skipped |
| gcc ASan+UBSan, `-DNGX_DEBUG_PALLOC=1` | PASS: 7110 tests, no sanitizer reports | PASS: 7121 tests, no sanitizer reports |
| `TEST_NGINX_UNSAFE=1` subset (19 files), gcc | PASS, 523 tests | not rerun |
| `TEST_NGINX_UNSAFE=1` subset, ASan | `binary_upgrade.t` fails, caused by this environment (see below) | not rerun |

Notes on the results:

- The ASan count differs only because `http_listen.t` skipped itself in the "before" run: it couldn't get the port range it needs, "no requested ranges".
- The 38 skipped files are skipped for these reasons:
  - Software not installed on this host: SCGI 7, uwsgi 4, memcached 4, `Cache::Memcached::Fast` 1, GD 1, `Win32API::File` 1.
  - Not run deliberately: running as root 3, binding a wildcard address on a production host 2, an engine test that leaves coredumps 1.
  - Gated by `TEST_NGINX_UNSAFE`: a long test 1 and orphan process groups 3. These were run separately.
  - Features not built or not available: no image_filter 2, no control_api 2, no mmdb 2, no OpenSSL 3.5 1, no kTLS 1, not win32 1.
  - Incompatible with sanitizers 1.
- The `binary_upgrade.t` failure under ASan comes from the environment. nginx re-execs itself with a cleared environment, so `ASAN_OPTIONS=detect_leaks=0` is lost and LeakSanitizer reports nginx's deliberate exit-time allocations. Startup under ASan is also sometimes slower than the test waits for.

## Leads rejected or not fixed

Static analysis produced 209 reports; all were triaged as false positives or not fixed:

- **cppcheck 2.22, 52 reports:** 51 rejected as deliberate nginx idioms or false positives, such as the configuration save/restore pattern, `mmap(MAP_ANON)` with fd -1, and macros from the perl and GeoIP headers. One became lead L2 below.
- **clang scan-build 19, 48 reports:** all rejected.
- **gcc `-fanalyzer`, 109 reports:** all rejected.
- **Of the 157 scan-build and `-fanalyzer` reports**, 12 were traced individually: the fastcgi/scgi/uwsgi `ignored` array, the try_files script engine, the ssl_preread ALPN buffer, the request body temp file, QUIC BPF `fds[1]`, the OpenSSL compat secret, the udp `c->udp` check and the fd "leaks". All 12 were false positives. The remaining ~145 are null-dereference reports in QUIC, queue and iovec code that follow the same invariant patterns. **They weren't traced one by one.**

Bugs confirmed but not fixed:

| Lead | Status |
|---|---|
| nginx/nginx#1955, HTTP/2 request trailers close the connection with GOAWAY | Confirmed by reading `ngx_http_v2_state_headers()`. A fix needs trailer handling in the HTTP/2 request body path, which is a design change rather than a minimal fix. |
| L2, xslt filter: `ngx_http_xslt_sax_error()` clamps `n` to `NGX_MAX_ERROR_STR` rather than `NGX_MAX_ERROR_STR - 1` | Proved by reading. A libxml2 message that's truncated at 2048 bytes is logged together with its terminating NUL byte. This is cosmetic, has no reproducer and isn't fixed. |
| L11, `access_log` with variables, `root /;` and `disable_symlinks` | Found by the L10 review. The root test checks the worker's current directory instead of `/`. It only affects whether a log line is written. |
| L12, `disable_symlinks from=` with a trailing slash | Pre-existing, logging only. Not fixed. |
| L13, regex `alias` locations with variables in `access_log` | Pre-existing. Log entries for non-static responses are lost. Not fixed; it needs a design decision. |

**Upstream open bug reports:** 51 issues labelled `bug` were collected (`work/upstream-open-issues.tsv` in the working directory). These were examined and are in the tables above: #1779, #1977, #1915, #1900 and #1955. #1671 (UBSan nonnull in `ngx_sprintf_str()`) was read but no reproducer was attempted. The gcc ASan+UBSan suite run, which logs at debug level, gave no report for it, probably because gcc doesn't instrument the `memcpy()` builtin. The clang UBSan runtime available here needs a newer CPU than this host has. **The other 45 open bug reports were not examined.**

**Upstream commits missing from the fork:** none. The fork's `master` was level with `nginx/nginx` `master`.

## Not covered

- **Modules not built:** `http_image_filter_module` (no libgd, libpng or libjpeg headers on this host) and `google_perftools_module`. Every other `--with-*` option from `auto/configure --help` was enabled. libxml2, libxslt, GeoIP, zlib and libatomic_ops were built from source because the host has no sudo.
- **Platforms:** Linux x86-64 only. win32, kqueue, event ports, `/dev/poll`, and 32-bit or big-endian targets were not built or reviewed.
- **Sanitizers:** only gcc's ASan+UBSan. clang's sanitizer runtime from conda-forge needs x86-64-v3, and the host CPU is baseline x86-64. No MSan, TSan or fuzzing.
- **Manual review:** the high-risk areas listed in the task were not systematically hand-reviewed:
  - request line, header and chunked parsing;
  - HTTP/3/QUIC framing;
  - proxy, FastCGI, uwsgi and gRPC response parsing;
  - mail, stream and the config parser;
  - error paths.

  Review was limited to the code paths of the leads above. This is the largest gap in this report.
- **New findings:** no new remotely triggerable memory-safety or request-smuggling issue was found. All four fixed bugs had already been reported publicly upstream.

## Decisions

The repository owner approved all four decisions on 2026-11-16.

1. **Cherry-picks from open, unmerged upstream PRs:** #1780, #1918 and #1903. These are not "already fixed upstream". Each was reviewed and tested here. Their authors and messages are kept unchanged, and my regression tests are in separate `Tests:` commits. Approved.
2. **The HTTP/2 fix is my own.** Upstream has no PR for #1977. Its approach records the real length of skipped fields and marks them with `field_start = NULL`. Approved for offering upstream; see [Upstream submission](#upstream-submission).
3. **`tests/regression/`:** this directory is new in this repository. It needs the nginx-tests `lib/` to run. Approved.
4. **Docs page facts:** see `DOCS-REPORT.md` in the docs branch. Approved.

## Upstream submission

The HTTP/2 fix is prepared for nginx/nginx as commit `ca3ea10be` on a local branch, `h2-skipped-field-1977`. The branch is based on upstream `master` at `2a3a19c6f` and follows upstream's CONTRIBUTING rules:

- the source change only, with no `tests/` directory;
- commit lines no longer than 72 characters;
- a `Closes: https://github.com/nginx/nginx/issues/1977` trailer.

On that branch, the regression test and all 32 nginx-tests `h2*.t` files (849 tests) pass.

The branch hasn't been pushed and no pull request has been opened. Opening one posts publicly under the owner's GitHub account. Before it can be merged, the owner must agree to the F5 Contributor License Agreement by commenting on the pull request. Upstream keeps its tests in nginx/nginx-tests, so the regression test would be a separate contribution there.

# Bug fix report: branch `claude/bugfixes-and-docs`

This report covers a bug hunt in nginx 1.31.9 (fork `kool277/nginx`), done
on 2026-11-14 on one Linux x86-64 host. It reports coverage, not
completeness: it lists what was searched, what was found, and what was not
covered.

## Branch state

| | |
|---|---|
| Branch | `claude/bugfixes-and-docs`, from `master` at `2a3a19c6f` |
| Head | the commit that adds this version of the report (the last code commit is `6522701c3`) |
| Compared with `upstream/master` (nginx/nginx) | ahead by the commits on this branch, including this report and a `workspace/` copy of the working notes; 0 behind. The fork's `master` was level with upstream when the work started. |

## Bugs fixed

| Area | Symptom | Root cause | Commits | How verified |
|---|---|---|---|---|
| Configure (`auto/make`) | `make` fails with "No rule to make target" when `--builddir` contains `.c`, `.cc`, `.cpp` or `.S` (for example `objs.clang`, or a Debian CI temp dir with `.S`). Upstream issue nginx/nginx#1779. | The sed substitutions that turn source paths into object paths weren't anchored, so later expressions matched the build directory inside paths that were already translated. | `529c94dad` (cherry-pick of open upstream PR nginx/nginx#1780, author kept), `f5bbcc9f5` (test) | `tests/regression/configure_builddir_suffix.t`: 4/4 fail before, 4/4 pass after. The independent review found the default `objs` Makefile byte-identical before and after, and checked win32 and POSIX sh/BSD sed. Found while building this branch with clang into `objs.clang`. |
| HTTP/2 | A request whose header block resets the stream (for example `:status` in a request), followed by a literal header field, closed the whole connection with GOAWAY(PROTOCOL_ERROR), "client sent zero header name length", so every stream on it was lost. Upstream issue nginx/nginx#1977 (no upstream fix). | `ngx_http_v2_state_field_skip()` doesn't set `field_start`/`field_end`, but `ngx_http_v2_state_process_header()` computed the skipped field's lengths from those stale pointers. The same stale lengths were charged against the header list limit. | `7b185de7a` (own fix + test) | `tests/regression/h2_reset_stream_skipped_field.t` fails before (2 of 6 checks) and passes after. The first review found a regression in the first version of the fix (a mid-field `client_header_timeout`), which was fixed before commit. The reviewer's 11 edge cases pass: timeouts mid-field, refused streams, a CONTINUATION flood (now ENHANCE_YOUR_CALM, bounded), split reads, Huffman fields. All nginx-tests `h2*.t` pass. |
| Core (`ngx_inet6_addr`) | `1:2:3:4:5:6:7::` and an IPv4 tail of `255.255.255.255` were rejected (`listen`, `allow`, `set_real_ip_from`, `geo`, realip), while `:1::` and `1::2:` were accepted. Upstream issue nginx/nginx#1915. | Trailing `::` after 7 groups failed the final group count; `ngx_inet_addr()` returns `INADDR_NONE` for 255.255.255.255; a single leading or trailing `:` wasn't checked. | `66f2ad789` (cherry-pick of open upstream PR nginx/nginx#1918, author kept), `f2c95042f` (test) | `tests/regression/inet6_addr_parse.t`: 6/9 fail before, all pass after. The independent review compared the parser with glibc `inet_pton()` on about 21 million generated inputs under ASan and UBSan. Every input whose result changed now agrees with `inet_pton()`. There were no sanitizer reports. |
| Log (`access_log`) | With variables in the `access_log` path and `disable_symlinks on`/`if_not_owner`, requests to multi-segment URIs weren't logged, and the error log said `testing "..." existence failed`. Upstream issue nginx/nginx#1900. | The root test truncated the path with `'\0'` but left `path.len` at root + URI. `ngx_open_file_wrapper()` walks by length, so it opened `root/URI`. | `e577a461d` (cherry-pick of open upstream PR nginx/nginx#1903, author kept), `4c3b64353` (test) | `tests/regression/access_log_variables_disable_symlinks.t`: 3/4 fail before, all pass after. The independent review checked `on`, `if_not_owner`, `from=`, alias, `$var` roots and symlinked roots (still rejected), and ran `access_log*.t` and `http_disable_symlinks.t`. |
| Log (`access_log`), `root /` | With `root /;` and variables in the `access_log` path, the log entry of every request not served by the static module was dropped: `return`, proxied and 404 responses, and 400 responses to invalid request lines. The error log said `testing "" existence failed`. Found by the L10 review (lead L11). | `root /` is stored as an empty string, and the log module's root test tested that empty path. With `disable_symlinks off`, the default, it failed with ENOENT. With `on` or `if_not_owner`, it tested the worker's current directory. | `0ab0fca42` (own fix + test) | `tests/regression/access_log_variables_root_slash.t`: 4 of 6 checks fail before, all pass after. The independent review found no defects. It checked that the `"/"` literal is never written to, and that a zero root length occurs only for `root /`. |
| Disable symlinks, `from=` with a trailing slash | With `disable_symlinks on from=<root>/` and a symbolic link above the root, files under the root were served, but the root directory without an index file returned **500** with `[crit] openat() ... failed (20: Not a directory)` instead of 403. Requests with variables in the `access_log` path weren't logged. Found by the L10 review (lead L12). | When tested as a directory, the `from` directory itself is one byte shorter than a `from` value that ends with a slash. `ngx_http_set_disable_symlinks()` therefore checked the whole path. | `6522701c3` (own fix + test) | `tests/regression/disable_symlinks_from_trailing_slash.t`: 4 of 7 checks fail before, all pass after. The review showed that the first version also exempted a symlinked **file** named by `from=` with a trailing slash (403 became 200). The fix was narrowed to directory tests (`of->test_dir`), and a check guards it. Symbolic links inside `from` still return 403. The fix doesn't weaken the security check: every component of an exempted path is inside the trusted prefix. |

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
| gcc ASan+UBSan, `-DNGX_DEBUG_PALLOC=1` | PASS: 7110 tests, no ASan reports (UBSan: see the correction below) | PASS: 7121 tests, no ASan reports (UBSan: see the correction below) |
| gcc, also with `--with-control-api --with-file-aio --with-pcre-jit --with-compat` (rerun 2026-11-16 on the branch head) | not run | PASS: 7227 tests, 36 files skipped; the Control API tests now run |
| ASan+UBSan with the same options (rerun 2026-11-16) | not run | PASS: 7227 tests, no ASan reports (UBSan: see the correction below) |
| gcc, with the L11 and L12 fixes (2026-11-19) | – | PASS: 7216 tests, 37 files skipped. `http_listen.t` skipped itself: "no requested ranges", meaning the port range it needs was in use. |
| ASan+UBSan, with the L11 and L12 fixes (2026-11-19) | – | PASS: 7227 tests, 36 files skipped. For sanitizer reports, see the note below. |
| `TEST_NGINX_UNSAFE=1` subset (19 files), gcc | PASS, 523 tests | `control_api_unix.t`, `control_api_upgrade.t`, `binary_upgrade.t`: PASS (24 tests); the rest not rerun |
| `TEST_NGINX_UNSAFE=1` subset, ASan | `binary_upgrade.t` fails, caused by this environment (see below) | not rerun |

Notes on the results:

- The ASan count differs only because `http_listen.t` skipped itself in the "before" run: it couldn't get the port range it needs, "no requested ranges".
- The 38 skipped files are skipped for these reasons:
  - Software not installed on this host: SCGI 7, uwsgi 4, memcached 4, `Cache::Memcached::Fast` 1, GD 1, `Win32API::File` 1.
  - Not run deliberately: running as root 3, binding a wildcard address on a production host 2, an engine test that leaves coredumps 1.
  - Gated by `TEST_NGINX_UNSAFE`: a long test 1 and orphan process groups 3. These were run separately.
  - Features not built or not available: no image_filter 2, no control_api 2, no mmdb 2, no OpenSSL 3.5 1, no kTLS 1, not win32 1.
  - Incompatible with sanitizers 1.
- **Correction (2026-11-19): "no sanitizer reports" was wrong for UBSan.** That statement came from Test::Nginx's check, which only looks for `Sanitizer` lines in each test's `error.log`. It never sees UBSan `runtime error` lines, and it doesn't see reports that nginx prints to stderr before it daemonizes. Each test file was therefore run again on its own, with its test directory kept and searched (`work/sanscan.sh` in the working directory). Results:
  - There were no AddressSanitizer errors.
  - **Misaligned 32-bit loads and stores** (about 800 reports) come from deliberate code paths: MD5, HTTP/2 frame parsing and writing, QUIC transport, and `ngx_http_parse.c`. nginx uses unaligned word access on purpose where `NGX_HAVE_NONALIGNED` is set, as it is on x86 (`auto/os/conf:92`).
  - **NULL pointers passed to `memcpy()`/`memcmp()` with length 0** (about 470 reports in about 20 places). The biggest is `ngx_sprintf_str()` (`ngx_string.c:586`, 362 test files), triggered by debug logging. That is upstream issue nginx/nginx#1671, so the earlier statement that this suite gives no report for #1671 was also wrong. Others are in the file cache, variables, proxy, upstream zone, sticky, mail auth_http, scripts, QUIC and the resolver. Open upstream PRs #1672, #1681, #1682 and #1691 cover some of them.
  - **Shift counts that are too large:** see lead L16. **A left shift of a negative value:** `ngx_resolver.c:2359`.
  - None of these reports came from the code changed on this branch. All of them come from the base nginx code.
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
| nginx/nginx#1955 (L9), HTTP/2 request trailers close the connection with GOAWAY | Confirmed by reading `ngx_http_v2_state_headers()`. **A design was proposed on 2026-11-19 and awaits the owner's approval.** It would treat an odd stream ID at or below the last one as a trailer section on an open stream. The block would be decoded through HPACK so that the dynamic table stays in sync, then discarded, and the request body would end like a zero-length DATA frame with END_STREAM. Trailers without END_STREAM, or with pseudo-headers, would get RST_STREAM PROTOCOL_ERROR. Trailers on a stream that nginx already closed would be decoded and ignored. |
| L2, xslt filter: `ngx_http_xslt_sax_error()` clamps `n` to `NGX_MAX_ERROR_STR` rather than `NGX_MAX_ERROR_STR - 1` | **Rejected: it can't be observed.** A libxml2 message of more than 6,000 bytes was logged live. `ngx_log_error()` formats into its own `NGX_MAX_ERROR_STR` buffer after a prefix of about 60 bytes, so the line ends at 2047 bytes and the NUL byte is never written. |
| L11, L12 | **Fixed**, see [Bugs fixed](#bugs-fixed). |
| L13, regex `alias` locations with variables in `access_log` | Reproduced. The root test checks the whole aliased file path as a directory: a `return` for an existing file fails with ENOTDIR and a 404 with ENOENT, and the log entry is dropped. **Awaits the owner's choice** between: A (recommended), test the directory part of the aliased path; B, skip the test for regex aliases, which removes its protection against log files for request-controlled paths; C, test the alias's static prefix, which needs a new configuration field. |
| L14, `ngx_http_map_uri_to_path()` with an empty URI | Found by the L11 review. For a request rejected before its URI is parsed, it calls `ngx_copy()` with a NULL source and length 0 (`ngx_http_core_module.c:2051`). That's undefined behaviour in C, but harmless in practice. Not fixed. |
| L15, `root $var` with an empty `$var` | Found by the L11 review. `ngx_get_full_name()` tests the first byte of an uninitialised reserved area, so whether the prefix is added varies between runs. Not fixed. |
| L16, `least_time`: shift count too large | Found by the sanitizer scan. In `ngx_http_upstream_least_time_eta()` (`:434`) and its stream version (`:424`), `rt >>= (now - peer->checked) / (peer->fail_timeout + 1)` shifts by 64 or more when a peer hasn't been checked for 64 fail timeouts, or ever (the scan saw a count of 1795183531). That's undefined behaviour. On x86 the count wraps modulo 64, so the decayed response time can come back instead of reaching 0. Not fixed; it's a small fix (use 0 when the count is 64 or more) and awaits approval. |

**Upstream open bug reports:** 51 issues labelled `bug` were collected (`work/upstream-open-issues.tsv` in the working directory). These were examined and are in the tables above: #1779, #1977, #1915, #1900 and #1955. #1671 (UBSan nonnull in `ngx_sprintf_str()`) was read but no reproducer was attempted. **Correction (2026-11-19):** the gcc ASan+UBSan build does reproduce it, in 362 test files. The reports went to each test's `error.log`, which Test::Nginx's sanitizer check doesn't read for UBSan. See [Test results](#test-results). Open upstream PR #1672 fixes it. It's not cherry-picked: that needs the owner's sign-off (decision 1). **The other 45 open bug reports were not examined.**

**Upstream commits missing from the fork:** none. The fork's `master` was level with `nginx/nginx` `master`.

## Not covered

- **Modules not built:** `http_image_filter_module` (no libgd, libpng or libjpeg headers on this host) and `google_perftools_module`. Every other module `--with-*` option from `auto/configure --help` was enabled. **Correction (2026-11-16):** until then, the builds also lacked `--with-control-api`, `--with-file-aio`, `--with-pcre-jit` and `--with-compat`, because the script that listed the options missed names with hyphens. They are now enabled, and the suites were rerun with them; see [Test results](#test-results). libxml2, libxslt, GeoIP, zlib and libatomic_ops were built from source because the host has no sudo.
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

### Pending decisions (2026-11-19)

These need the owner's approval before any code is written:

5. **L9, HTTP/2 request trailers (nginx/nginx#1955):** the design in [Leads rejected or not fixed](#leads-rejected-or-not-fixed).
6. **L13, regex `alias` with variables in `access_log`:** option A, B or C.
7. **L16, `least_time` shift count:** a small own fix with a regression test.
8. **UBSan NULL-pointer reports:** whether to cherry-pick the open upstream PRs #1672 (`ngx_sprintf_str()`, #1671), #1681 (proxy), #1682 (sticky) and #1691 (three more call sites), as decision 1 did for #1780, #1918 and #1903.

## Upstream submission

The HTTP/2 fix is offered to nginx/nginx as commit `b9e9470ad` on branch `h2-skipped-field-1977`. The branch is based on upstream `master` at `2a3a19c6f` and follows upstream's CONTRIBUTING rules:

- the source change only, with no `tests/` directory;
- commit lines no longer than 72 characters;
- no trailing dot on the subject line;
- a `Closes: https://github.com/nginx/nginx/issues/1977` trailer.

On that branch, the regression test and all 32 nginx-tests `h2*.t` files (849 tests) pass.

On 2026-11-16, with the owner's approval, the branch was pushed to the fork and opened as nginx/nginx#1991 (https://github.com/nginx/nginx/pull/1991). Upstream keeps its tests in nginx/nginx-tests, so the regression test would be a separate contribution there.

On 2026-11-18 a reviewer asked for two changes:

- **Drop the trailing dot from the commit subject.** Done. The commit was reworded from `ca3ea10be` to `b9e9470ad`. Only the subject's final dot changed; the code and the author are the same.
- **Agree to the F5 Contributor License Agreement.** The owner has to do this personally, in a PR comment. The CLA check fails until then.

The PR's other checks (commit message, whitespace, version bump and check-pr) wait for a maintainer to approve the run, as they do for every first-time contributor. The runs listed as failed for `ca3ea10be` on 2026-11-16 never started a job, so they checked nothing. Upstream's commit message, whitespace and version bump checks were run locally on `b9e9470ad`, and all three pass. check-pr calls a workflow in a private repository and couldn't be run.

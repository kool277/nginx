# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this directory is

This is a working directory for two forks, not a project. The outer git repo has no commits and stays untouched (ledger D1), so don't commit here. Run git inside each repo.

| Path | What it is | Git |
|---|---|---|
| `nginx/` | nginx C source, fork `kool277/nginx`. Full clone (blame and cherry-pick need history) | `origin` = fork; `upstream` = nginx/nginx with push set to `no-push`; `upstream-pr/<n>` = fetched upstream PR heads |
| `nginx.docs/` | Hugo docs site, fork `kool277/nginx.docs` of nginx/documentation. Partial clone (`--filter=blob:none`), so old blobs download on demand | Same remote layout. Has its own `CLAUDE.md`, which imports `AGENTS.md` and the F5 style-guide agent |
| `nginx-tests/` | nginx/nginx-tests at `c0b7894`. Read-only reference and test runner | Don't commit |
| `deps/` | User-space toolchain and libraries (see Host constraints) | Not in git |
| `work/` | Build and test scripts, the docs example harness, test results, analysis output, scratch files | Not in git |

A backup copy of this file and `LEDGER.md` lives in the nginx fork, in `workspace/` on branch `claude/bugfixes-and-docs`. The copies here are the working ones. Refresh the backup in the same commit whenever you commit to that branch.

**`LEDGER.md` is the running record. Read it first.** It holds decisions D1–D19, bug leads L1–L16 with their status, the docs page log with source citations, and dated session notes. Add a dated entry for every decision, commit or push. The deliverables are committed in the repos and must be kept current: `nginx/BUGFIX-REPORT.md` and `nginx.docs/DOCS-REPORT.md`. Owner sign-off is tracked in their "Decisions" sections.

## Host constraints

- **The host also runs live production services** (see "Production caution" in `../CLAUDE.md`). Run builds and tests niced, with at most 6 jobs for make and 8 for `prove` (the scripts below already do this).
- **Disk:** the hard floor is 2 GB free on `/`. On 2026-11-19 the owner approved deleting the clang toolchain (`deps/mamba`), the Go module cache and `objs.doc`, which left 3.3 GB free. Don't prune the user's Docker images or cache. Build Hugo with `--renderToMemory`, never into `public/`.
- **No sudo or apt.** Every tool comes from `deps/`:
  - `deps/prefix`: static zlib, libatomic_ops, libxml2, libxslt and GeoIP.
  - `deps/hugo/hugo` (0.152.2 extended) and `deps/go`.
  - `deps/node/node_modules/.bin/`: `markdownlint`, `markdown-link-check`, `mmdc`.
  - `deps/perl5`: test Perl modules (`PERL5LIB=deps/perl5/lib/perl5`).
- The network is slow (about 47 KB/s), so avoid large fetches.

## nginx: build

```sh
W=/home/ubuntu/projects/ngingx
$W/work/build.sh gcc                                    # -> nginx/objs.gcc/nginx
$W/work/build.sh asan gcc "-fsanitize=address,undefined -fno-omit-frame-pointer -DNGX_DEBUG_PALLOC=1" "-fsanitize=address,undefined"
NOPERL=1 $W/work/build.sh ctl                           # without the embedded perl module
```

clang is no longer available. The `deps/clang` wrapper is still there, but the compiler it called was deleted to free disk space. The last clang build is `objs.clang`, and the reports' "clang 19 clean" results refer to it. A new clang build would need a fresh download, and conda-forge's clang 19 package takes hours at this network speed.

- `build.sh <variant> [cc] [extra-cc-opt] [extra-ld-opt]` enables every `--with-*` module the host can build. The exceptions are image_filter (no libgd) and google_perftools. It always builds with `--with-debug` and `-Werror`. It writes `objs.<variant>/configure.log` and `make.log`.
- Build directories must be `nginx/objs.<variant>`, one level deep, because the perl module's `Makefile.PL` assumes that depth. `.git/info/exclude` ignores them.
- `configure` also writes `nginx/Makefile` (gitignored), which points at whichever variant was configured last. Use `make -f objs.<variant>/Makefile` instead.
- A build directory containing `.c`, `.cc`, `.cpp` or `.S`, such as `objs.clang`, breaks `make` on any branch without the L1 fix (`529c94dad`). That includes upstream `master` and PR branches. Use `objs.llvm` there.
- Use the gcc ASan build for sanitizers. clang's sanitizers didn't work on this host even before clang was deleted: the conda runtime needs x86-64-v3.

## nginx: tests

```sh
work/runtests.sh gcc  mylabel                       # full nginx-tests suite, prove -j8
ASAN=1 work/runtests.sh asan mylabel -j6 .          # sets ASAN_OPTIONS/UBSAN_OPTIONS
work/runtests.sh gcc  mylabel h2_headers.t          # single nginx-tests file (always prove -v)
```

`runtests.sh` runs from `nginx-tests/` with `TEST_NGINX_BINARY=nginx/objs.<variant>/nginx` and `TMPDIR=work/tmp`. Output goes to `work/results/<label>/prove.log`.

The fork's own regression tests are in `nginx/tests/regression/`; that directory exists only on the fork branch. Run them from `nginx/`:

```sh
TEST_NGINX_BINARY=$PWD/objs.gcc/nginx PERL5LIB=../deps/perl5/lib/perl5 \
    prove -v -I ../nginx-tests/lib tests/regression/h2_reset_stream_skipped_field.t
```

`configure_builddir_suffix.t` needs only `make` and a compiler, not a binary.

Expected results on the branch head: gcc and ASan both pass 7227 tests, with 36 files skipped, and the 9 regression test files (98 tests) pass on both. The reasons for every skip are in `BUGFIX-REPORT.md`. Some files are skipped on purpose and shouldn't be enabled on this host: they need root or a wildcard `listen`. `TEST_NGINX_UNSAFE=1` files run separately. `binary_upgrade.t` fails only under ASan, because nginx clears its environment on re-exec and loses `ASAN_OPTIONS`; that's a known artifact of this setup, not a bug.

Test::Nginx's "no sanitizer errors" check never sees UBSan `runtime error` lines, so a passing ASan run says nothing about UBSan. To find them, run each file alone with its test directory kept and searched: `cd nginx-tests && ls *.t | SANSCAN_OUT=$W/work/results/<label> xargs -P4 -n1 sh $W/work/sanscan.sh`. The last scan (2026-11-20) left 44 reports outside the deliberate misaligned accesses, all in base nginx code; see `BUGFIX-REPORT.md`.

A test config without `%%TEST_GLOBALS%%` gets a debug error log. A flood test then writes gigabytes: one reached 1.2 GB and pushed free space below the floor. Keep such logs out of flood tests, or watch `df` while they run.

Static analysis output is in `work/analysis/` (cppcheck, scan-build, gcc `-fanalyzer`). All of it was triaged as leads L2–L6. Build `compile_commands.json` with `python3 work/mkcc.py <make.log> <out.json> <nginx-dir>`. cppcheck needs `-DCPPCHECK` and gcc target macros, or every file stops at an `#error` (D11).

## nginx: branches and commits

- `claude/bugfixes-and-docs` is the fork's work branch. It carries `BUGFIX-REPORT.md` and `tests/regression/`, which upstream doesn't have. This clone fetches only `master` from `origin`, so there is no `origin/claude/bugfixes-and-docs` ref: check the fork's branch with `git ls-remote origin` before pushing. The branch and the fork's `master` are based on `2a3a19c6f`. On 2026-11-21 upstream `master` was 19 commits ahead, at `2e8440bcd` (the 1.31.9 release and later fixes), and wasn't merged in.
- `h2-skipped-field-1977` is upstream PR **nginx/nginx#1991**. It's one commit, based on upstream `master` at `2a3a19c6f`, and contains source changes only. The owner agreed to the F5 CLA on the PR on 2026-11-18, all its checks pass, and it waits for a maintainer's review. Only the owner may agree to a CLA: never post that text for them.
- Upstream PR **nginx/nginx#2008**, from another contributor, addresses #1955 with the same design as L9 but misses cases that L9 handles. With the owner's approval, a comment on it on 2026-11-21 listed them and offered the regression test (decision 9 in `BUGFIX-REPORT.md`). Don't open a second PR for #1955.
- Upstream commit format:
  - The subject has an area prefix (`HTTP/2:`, `Core:`, `Upstream:`, ...) and **no trailing dot**. The maintainer asked for this on #1991; older commits on the fork branch still end with a dot.
  - Lines are at most 72 characters.
  - Fixes end with a `Closes: https://github.com/nginx/nginx/issues/N` trailer.
  - Upstream PRs contain no `tests/` changes. Upstream keeps its tests in nginx/nginx-tests.
  - Follow the nginx code style: https://nginx.org/en/docs/dev/development_guide.html#code_style
- If an open upstream PR already has a correct minimal fix, use `git cherry-pick -x` and keep its author and message unchanged. Put your regression test in a separate `Tests: ...` commit (D9, D12). Cherry-picking an unmerged PR needs owner sign-off.
- Pushing to upstream, opening PRs and commenting are public actions under the owner's account. Ask first. Pushes to the fork show upstream too: the fork has issues disabled, so `#N`, `nginx/nginx#N` and issue URLs in a commit message pushed to it add a "referenced" entry on that nginx/nginx issue or PR. Name upstream numbers in commit messages only where that link is wanted, such as a fix's `Closes:` trailer.
- A new memory-safety or request-smuggling bug that can be triggered remotely and that you found yourself stays on a local branch, unpushed, and goes to the owner (D4). Fixes for publicly reported upstream issues may be pushed.

## nginx.docs

`nginx.docs/CLAUDE.md` applies there: Conventional Commits (gitlint: title at most 60 characters, body lines at most 72), `ref` shortcodes for internal links, and the product-name list. This work adds rules of its own on top:

- **Scope is `content/nginx/` only.** Don't touch other product sections, `layouts/`, the theme, config or `.style-guide`. The one exception is three files in `content/includes/` that the owner had fixed on 2026-11-24 (decision 9: `custom-paths-jwt.md`, `docker-registry-instructions.md`, `credential-download-instructions.md`); change nothing else there. All pages are done: 117 of the 135 files changed, and the other 18 are section index files that hold only front matter. The owner approved decisions 9 to 11 on 2026-11-24 and decision 12 on 2026-11-25. `releases.md` must stay equal to `main` apart from `f5-product`. On 2026-11-25 the owner had the 319 anchors lost on pages 29 to 98 restored (`8be4c970`). Where an old anchor goes (decision 12 in `DOCS-REPORT.md`): when it maps to a whole section, a `<span id>` on its own line directly above that section; when its content now lives inside a section, on the specific step or paragraph that holds it. Never inside a heading line: Hugo copies it into the TOC and the id appears twice. The 91 older spans on steps and paragraphs (32 pages) stay where they are. Before editing any page, check for the `AUTOGENERATED FILE - DO NOT EDIT` marker; none of the pages in `content/nginx/` in this copy has it. Upstream `main` isn't merged in, and its commit `2f7284a5` overlaps 18 rewritten pages.
- **Technical accuracy (D14, approved):** the F5 agent says to flag facts rather than fix them. Here, fix a fact only when the nginx source or a running nginx proves it. Cite `file:line` in `LEDGER.md` and list each correction under "Defects fixed" in `DOCS-REPORT.md`. Keep NGINX Plus-only facts. Change Plus examples only where open-source nginx or a public standard proves them wrong (D17, D19). Version notes name open-source releases only, taken from `git tag --contains`.
- **Per-page workflow:**
  1. Rewrite the page to the how-to template.
  2. Check every directive, default, context and version against the `ngx_command_t` tables and `ngx_conf_merge_*` calls in `nginx/src`.
  3. Make every `nginx` block pass `nginx -t`.
  4. Run the complete example and the Verify steps live.
  5. Add a Mermaid diagram only where a flow, hierarchy or state machine needs one, never as decoration, and put a text description next to it.
  6. Run lint, link-check and Hugo, and anchor checks 1 and 2 with `idcheck.py` (owner, 2026-11-25: on every page from now on).
  7. Get an independent review that follows the page literally on a running nginx, and fix what it finds.
  8. Commit, then update `DOCS-REPORT.md`.

```sh
W=/home/ubuntu/projects/ngingx; cd $W/nginx.docs
HUGO_CACHEDIR=$W/deps/hugocache PATH=$W/deps/go/bin:$PATH $W/deps/hugo/hugo --renderToMemory   # expect 3598 pages, 0 warnings
$W/deps/node/node_modules/.bin/markdownlint -c .markdownlint.yaml -- content/nginx/<path>.md
$W/deps/node/node_modules/.bin/markdown-link-check content/nginx/<path>.md
$W/work/doctest/auto.sh content/nginx/<path>.md        # each nginx block: tries main/http/server/location/stream
WRAP=server V=1 $W/work/doctest/check.sh content/nginx/<path>.md 3   # one block, one context, show output
$W/work/doctest/mmd.sh content/nginx/<path>.md         # validate mermaid blocks
# anchor checks: render main from a worktree (enableGitInfo needs git) and the branch into /dev/shm, then
python3 -I $W/work/doctest/idcheck.py /dev/shm/x/main /dev/shm/x/new [/dev/shm/x/before]   # expect PASS
```

- `idcheck.py` check 1: every id inside `<main>` of each `main` page exists on the branch page (code-block ids `id-<16 hex>` ignored). Check 2: no page has an id twice unless `main` has the same duplicate. Check 3 (with a third render): no in-site fragment link that worked before a commit is broken after it. Build `main` with `git worktree add --detach /dev/shm/x/wt main`, and remove the worktree afterwards. The 2026-11-25 mapping of old anchors to sections is `work/doctest/anchor-map-2026-11-25.tsv`.

- `check.sh` uses `nginx/objs.ctl/nginx` unless `NGINX_BIN` says otherwise. That build has no Perl module. Don't point the harness at `objs.gcc`: nginx clears its environment before embedded Perl starts, so any block with an `http` context fails with "Can't locate nginx.pm". `nginx -t` checks that directories such as `working_directory` exist, so test such blocks on a copy of the page with the path replaced. To make a page's examples testable without root, the harness:
  - rewrites `/etc/nginx`, `/var/log/nginx` and `/data/` into a temporary prefix;
  - moves ports below 1024 to 18000+port;
  - maps `*.example.com` and `*.example.org` hosts, except `www.`, to 127.0.0.1 (D15);
  - writes test certificates from `work/doctest/` for any `ssl_*` file paths.
- Baselines: "no new errors" is the bar. markdownlint stands at 1620 errors across `content/` (156 in `content/nginx`, all in `releases.md`, a known exception). Link-check's remaining reports are known false positives: Hugo `{#id}` anchors, root-relative images and example domains.
- `work/grpcprobe/` has a gRPC health server and client for the gRPC health-check page. The `work/fix_*.py` scripts were one-off edits to specific pages and reports, not reusable tools.
- Building third-party nginx modules (GeoIP2) was blocked by the permission system on 2026-11-17. Don't retry it or work around it.

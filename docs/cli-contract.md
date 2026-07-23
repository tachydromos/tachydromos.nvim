# tachy CLI contract

This is the single source of truth for how `tachydromos.nvim` invokes the
`tachy` binary. It was written by the CLI owner directly against the
implementation in `tachydromos/cmd/tachy` (commit `5118acf` at time of
writing, plus the `list`/`--format json`/`--request` additions made
alongside this doc) — every example below is real captured output, not a
guess. If the plugin's behavior and this doc ever disagree with the
binary's actual behavior, the binary wins and this doc is out of date;
file that as a bug against the CLI, don't silently work around it.

Binary name: `tachy`. Built via `make build` in `tachydromos/`, producing
`bin/tachy`.

## Contents

- [Global flags](#global-flags)
- [Blocking / process model](#blocking--process-model)
- [`tachy version`](#tachy-version)
- [`tachy list`](#tachy-list) — enumerate requests without executing them
- [`tachy run`](#tachy-run) — execute requests
- [JSON schemas](#json-schemas)
- [Environment / variable selection](#environment--variable-selection)
- [Exit codes and error surfaces](#exit-codes-and-error-surfaces)
- [Recommended plugin workflows](#recommended-plugin-workflows)
- [Known gaps / not yet supported](#known-gaps--not-yet-supported)
- [Command/flag summary table](#commandflag-summary-table)

## Global flags

Persistent on the root command, valid before any subcommand:

| Flag | Meaning |
|---|---|
| `--dir <path>` | Working directory that **relative** file/dir arguments are resolved against. Defaults to the process's current working directory. Absolute arguments ignore it. This does **not** affect environment-file discovery — see [Environment / variable selection](#environment--variable-selection). |

`-h`/`--help` works on every command and subcommand (cobra default).

## Blocking / process model

`tachy run` and `tachy list` are **synchronous, one-shot processes**: they
parse (and, for `run`, execute) everything, print their output, and exit.
There is no streaming/incremental protocol, no long-lived server mode, and
no partial-flush-then-more-later contract beyond normal stdout buffering.
In `--format json` mode, each request's result line is written to stdout
as soon as that request finishes (not buffered until the whole file
completes), so a plugin reading the child process's stdout incrementally
will see JSON lines arrive one at a time in real time — but there is no
separate "event" framing beyond "one JSON object per line." Because a
`run` invocation can take arbitrarily long (network requests, no
client-side timeout unless `@timeout` is set in the file), **the plugin
must invoke `tachy` as an async job** (e.g. `vim.system(..., { text = true
}, callback)` or `vim.uv.spawn`) and not block the UI thread waiting for
it to exit.

## `tachy version`

```
$ tachy version
tachy dev
```

Prints `tachy <version>` to stdout and exits 0. `<version>` is `dev` in a
plain `make build`; real releases set it via `-ldflags "-X
main.version=$(git describe --tags --always)"`. Not useful for feature
detection by itself — see [Known gaps](#known-gaps--not-yet-supported) for
how to detect whether `list`/`--format json`/`--request` exist on an
older binary.

## `tachy list`

```
tachy list <file.http|dir>... [--format text|json]
```

Parses the given files (or recursively walks given directories for
`*.http` files, matching only the `.http` extension) and prints each
request's identifying metadata — **no execution, no network I/O, no
environment resolution**. This is how the plugin discovers request names
(for "run request under cursor" / "run request by name" / a request
picker) without needing its own `.http` parser.

Requests are listed in source order, per file, in the order files were
discovered (`httpfile.Discover` sorts files alphabetically and
de-duplicates).

### `--format text` (default)

Tab-separated, one line per request, meant for humans/quick shell use —
**do not parse this for plugin logic, use `--format json`**:

```
$ tachy list sample.http
sample.http:5	LOGIN	POST	https://{{host}}/post
sample.http:12	GET_ONE	GET	https://{{host}}/get?token={{LOGIN.response.body.$.json.user}}
sample.http:17	FAILING	GET	https://{{host}}/status/500
```

Format: `<file>:<line>\t<label>\t<method>\t<url>\n`, where `<label>` is
the request's `Name` if it has one, else `METHOD URL`.

### `--format json`

Newline-delimited JSON (NDJSON): one compact JSON object per line, per
request. Real captured output:

```
$ tachy list sample.http --format json
{"type":"request","file":"/abs/path/sample.http","name":"LOGIN","label":"LOGIN","method":"POST","url":"https://{{host}}/post","line":5}
{"type":"request","file":"/abs/path/sample.http","name":"GET_ONE","label":"GET_ONE","method":"GET","url":"https://{{host}}/get?token={{LOGIN.response.body.$.json.user}}","line":12}
{"type":"request","file":"/abs/path/sample.http","name":"FAILING","label":"FAILING","method":"GET","url":"https://{{host}}/status/500","line":17}
```

See [`requestMeta` schema](#requestmeta-list-output) below for field
types. `url` is the **raw, unresolved** URL exactly as written in the file
(`{{var}}` placeholders are not substituted — `list` never resolves
variables).

If a file fails to parse, `list` emits a `file_error` JSON object for
that file (same shape as `run`, see below) to stdout, prints a
human-readable line to **stderr**, continues processing the remaining
files, and exits 1 at the end if any file failed. Directory-arg `list`
calls therefore may produce a mix of successful `request` lines and
`file_error` lines across the files found.

## `tachy run`

```
tachy run <file.http|dir>... [--env <name>] [--format text|json] [--request <name>]
```

Parses and executes every request in the given file(s)/dir(s), in source
order, per file. Within one file: one shared cookie jar (cookies set by
one request are sent on later ones) and one shared in-memory chaining
store (`{{NAME.response...}}` references — see
[Environment / variable selection](#environment--variable-selection)).
Chaining and cookies are **not** shared across different files in the
same invocation, and never persisted across separate `tachy run`
invocations (no `--persist` flag exists yet).

### `--env <name>`

Selects an environment by name from `http-client.env.json` /
`http-client.private.env.json`. See
[Environment / variable selection](#environment--variable-selection) for
exactly which directory is walked — it is **not** `--dir` or the
process's cwd, it's each individual `.http` file's own directory.
Omitting `--env` (or passing `--env ""`) means no environment file is
read at all; `{{var}}` placeholders that would have come from it are left
unresolved in the output (verbatim `{{var}}` text), not an error.

### `--request <name>`

Restricts execution to request block(s) whose `### NAME` **exactly**
matches `<name>` (case-sensitive), across all files given on the command
line. Unnamed requests can never be targeted this way. If the same name
appears more than once in a file (the parser does not enforce
uniqueness), **all** of them run — verified: a file with two `### SAME`
blocks and `--request SAME` executes both. If `<name>` matches nothing in
any of the given files, the process exits 1 with `tachy: no request
named "<name>" found in [<args>]` on stderr and **no** request lines are
emitted at all (verified — zero JSON lines, zero text output). A file
that contains no match for `<name>` is simply skipped for that
invocation; it is not itself an error unless nothing anywhere matched.

**Important for "run request under cursor":** running a single request
via `--request` does **not** run any other request in the file first —
including one it chains off of. If `GET_ONE` references
`{{LOGIN.response.body.$.json.user}}` and you `--request GET_ONE` without
also having run `LOGIN` earlier in the *same* `tachy` process, the
placeholder is left **verbatim, unresolved** in the request actually sent
(verified — the literal string `{{LOGIN.response.body.$.json.user}}` was
sent as the query value). The plugin should either: (a) warn the user
their request depends on an unrun chain, or (b) run the whole file
(`tachy run <file>` with no `--request`) when a request has visible
chaining dependencies, rather than trying to run only the one under the
cursor.

### `--format text` (default)

Human-readable, streamed to stdout as each request completes. Real
captured output (against `httpbingo.org`, a `.http` file with
`@host = httpbingo.org`, a `LOGIN` request chaining into a `GET_ONE`
request, and a `FAILING` request with `@expect-status-code 200` against a
`/status/500` endpoint):

```
### LOGIN
HTTP/2.0 200 OK (128ms)
Access-Control-Allow-Credentials: true
Access-Control-Allow-Origin: *
Content-Type: application/json; charset=utf-8
Date: Wed, 22 Jul 2026 07:48:02 GMT
...

{
  "json": { "user": "alice" },
  ...
}

### GET_ONE
HTTP/2.0 200 OK (60ms)
...

### FAILING
HTTP/2.0 500 Internal Server Error (57ms)
...
error: status 500 not in expected list [200]: runner: response status code not in @expect-status-code list

/abs/path/sample.http: one or more requests failed
tachy: one or more requests failed
```

Shape per request, in order:
1. `### <label>\n` — label is the request's `Name`, or `METHOD URL` if
   unnamed.
2. Pre-script log/test lines, if any (`  [log] ...`, `  [PASS]
   name`/`  [FAIL] name: message`), then `pre-request script failed,
   request not sent: <err>\n` **and nothing else for that request** if
   the pre-script errored (no HTTP call is made).
3. If sent: `<Proto> <Status> (<duration>)\n`, then headers
   (`Name: Value`, sorted alphabetically by header name — **not** source
   order), then a blank line and the raw body if non-empty.
4. Post-script log/test lines, if any.
5. `error: <err>\n` if the send itself failed or `@expect-status-code`
   didn't match.
6. A blank line separating this request's block from the next.

**Do not parse this for plugin logic.** Use `--format json`. This text
format has no stability contract — header ordering, wording, and
whitespace are free to change.

### `--format json`

NDJSON, one `request` object per executed request, written to stdout as
each request completes (see [Blocking / process model](#blocking--process-model)).
Real captured output for the same three-request file above (`LOGIN` /
`GET_ONE` / `FAILING`, pretty-printed here for readability — actual
output is one compact line per object):

```json
{
  "type": "request",
  "file": "/abs/path/sample.http",
  "name": "LOGIN",
  "label": "LOGIN",
  "method": "POST",
  "url": "https://{{host}}/post",
  "line": 5,
  "response": {
    "status_code": 200,
    "status": "200 OK",
    "proto": "HTTP/2.0",
    "duration_ms": 181,
    "headers": {
      "Content-Type": ["application/json; charset=utf-8"],
      "Date": ["Wed, 22 Jul 2026 08:01:18 GMT"],
      "...": ["..."]
    },
    "body": "{\n  \"json\": {\"user\": \"alice\"},\n  ...\n}\n"
  }
}
```

For the failing request (`@expect-status-code 200` against a 500
response), the object gains a top-level `error` field but **still
includes the `response`** — the HTTP round-trip succeeded, only the
expectation check failed, and the response is not discarded:

```json
{
  "type": "request",
  "file": "/abs/path/sample.http",
  "name": "FAILING",
  "label": "FAILING",
  "method": "GET",
  "url": "https://{{host}}/status/500",
  "line": 17,
  "response": {
    "status_code": 500,
    "status": "500 Internal Server Error",
    "proto": "HTTP/2.0",
    "duration_ms": 54,
    "headers": { "...": ["..."] },
    "body": ""
  },
  "error": "status 500 not in expected list [200]: runner: response status code not in @expect-status-code list"
}
```

A request whose URL never resolves (e.g. an unset `{{var}}` in the host,
or DNS/connection failure) has **`response` entirely absent** (omitted,
not `null` due to `omitempty` — check with your JSON library's
"key present" test, not just falsy) and a non-empty `error`:

```json
{"type":"request","file":"/abs/path/env-sample.http","name":"WHOAMI","label":"WHOAMI","method":"GET","url":"https://{{host}}/headers","line":3,"error":"building request for GET https://{{host}}/headers: parse \"https://{{host}}/headers\": invalid character \"{\" in host name"}
```

```json
{"type":"request","file":"/abs/path/neterr.http","name":"","label":"GET https://this-host-does-not-exist.invalid/get","method":"GET","url":"https://this-host-does-not-exist.invalid/get","line":1,"error":"sending GET https://this-host-does-not-exist.invalid/get: Get \"https://this-host-does-not-exist.invalid/get\": dial tcp: lookup this-host-does-not-exist.invalid: no such host"}
```

If a file fails to **parse** (before any request could run), `run` emits
one `file_error` object to stdout instead of any `request` objects for
that file, and continues to the next file given on the command line:

```json
{"type":"file_error","file":"/abs/path/bad.http","error":"parsing /abs/path/bad.http: parsing request line 1 (\"NOTAMETHODWITHSPACES this is not valid $$$ ???\"): httpfile: malformed request line"}
```

The same `file_error` shape is used if environment resolution itself
fails (a malformed `http-client.env.json`) — this is rare since a missing
env file is not an error, only a malformed one.

See [JSON schemas](#json-schemas) for full field tables.

## JSON schemas

All JSON output is **newline-delimited** (one `json.Encoder.Encode` call
per object — compact, no pretty-printing, trailing `\n`). Every object has
a `type` field the plugin should switch on first; treat unknown future
`type` values as forward-compatible no-ops rather than erroring.

### `request` (`run` output)

| Field | Type | Notes |
|---|---|---|
| `type` | `"request"` | Always this literal. |
| `file` | string | Absolute path to the `.http` file. |
| `name` | string | `### NAME`; **absent** (omitted, `omitempty`) if the request block is unnamed. |
| `label` | string | `name` if named, else `"METHOD URL"`. Always present, never empty. |
| `method` | string | Uppercased HTTP method (`GET` if the request line omitted one). |
| `url` | string | Raw, **unresolved** request-line URL as written (`{{var}}` placeholders intact). |
| `line` | number | 1-based source line of the request line. |
| `response` | object or absent | See `response` below. Absent (not `null`) if no HTTP response was received at all. |
| `error` | string or absent | Pre-script failure message, send failure message, or `@expect-status-code` mismatch message. Absent on full success. |
| `pre_script` | object or absent | See `script` below. Absent if the request has no pre-request script (not merely "script ran with no output"). |
| `post_script` | object or absent | Same, for the post-request script. Absent if `response` is absent (post-script only runs after a response is received) or the request has no post-script. |

### `response`

| Field | Type | Notes |
|---|---|---|
| `status_code` | number | e.g. `200`. |
| `status` | string | e.g. `"200 OK"`. |
| `proto` | string | e.g. `"HTTP/2.0"`, `"HTTP/1.1"`. |
| `duration_ms` | number | Integer milliseconds, rounded down (`time.Duration.Milliseconds()`); can be `0` for very fast local requests. |
| `headers` | object of string → string[] | **All** header values as arrays, even single-valued headers (`{"Content-Type": ["application/json"]}`) — never collapse to a bare string. Header names as returned by Go's `net/http` (canonical MIME case, e.g. `Content-Type`, `X-Forwarded-For`). |
| `body` | string | Raw response body as UTF-8 text. Binary bodies are **not** specially handled — treat as opaque/best-effort if you must display them (see [Known gaps](#known-gaps--not-yet-supported)). |

### `script`

| Field | Type | Notes |
|---|---|---|
| `logs` | string[] or absent | `client.log(...)` lines, in call order. Absent if empty (`omitempty`). |
| `tests` | object[] or absent | `client.test(...)` outcomes, in call order. Absent if empty. |
| `error` | string or absent | Uncaught Lua error (outside any `client.test`). For a pre-script, this means the request was never sent. |

### `tests[]` entry

| Field | Type | Notes |
|---|---|---|
| `name` | string | The `client.test(name, ...)` name. |
| `passed` | boolean | |
| `message` | string or absent | Assertion failure message from `client.assert`. Absent when `passed` is `true`. |

### `file_error` (`run` and `list` output)

| Field | Type | Notes |
|---|---|---|
| `type` | `"file_error"` | Always this literal. |
| `file` | string | Absolute path to the file that failed. |
| `error` | string | Human-readable Go error message (wrapped with `fmt.Errorf`, includes the underlying parse/IO error). Not machine-parseable beyond "non-empty means failure" — don't pattern-match on its text. |

### `requestMeta` (`list` output)

Same as `request` above minus everything execution-only: `type`, `file`,
`name`, `label`, `method`, `url`, `line` only — no `response`, `error`,
`pre_script`, `post_script`.

## Environment / variable selection

- `--env <name>` on `run` selects an environment by name from
  `http-client.env.json` / `http-client.private.env.json`.
- **Discovery is per-`.http`-file, not per-invocation or per-`--dir`.**
  For each file being run, `tachy` walks upward from **that file's own
  directory** (`filepath.Dir(path)`), not the process's cwd and not the
  `--dir` flag — verified experimentally: an env file placed next to the
  `.http` file was found and used even when the shell's cwd was a
  completely different directory and no matching env file existed there.
  (Note: `docs/usage.md` in the `tachydromos` repo currently describes
  this as "walked upward from the working directory" — that wording is
  stale/imprecise; the code and this doc's verified behavior are ground
  truth. Flagged for a doc fix on the CLI side.)
- At each directory level from the file's directory up to filesystem
  root, both `http-client.env.json` and `http-client.private.env.json`
  are read (if present; missing files are not an error). The **private**
  file overrides the **public** file at the same level, and a directory
  **closer to the `.http` file** overrides a more distant ancestor on
  conflicting keys — non-conflicting keys from ancestors still apply.
- If `--env` is omitted entirely, no environment file is read at all
  (not even to check it exists) and every `{{var}}` that would have come
  from one is left as literal, unresolved text in output — this is not
  an error.
- Variable resolution precedence (for a plain, non-`$`-prefixed name):
  1. `@name = value` file-header declarations, then block-preamble
     declarations (block wins on conflict).
  2. The selected environment's variables (see above).
  3. Runtime-set variables — a pre-request Lua script's
     `request.variables.set` / `client.global.set` (both write to the
     same place).
- `{{$env.NAME}}` reads the real OS environment of the `tachy` process
  (inherits from however the plugin spawned it) — a plain `{{NAME}}`
  never does. If the plugin wants to inject values from Neovim into a
  request, prefer `@name = value` overrides via a temp/generated file, or
  rely on the file's own env-file mechanism — there is currently no
  `--var name=value` CLI flag to inject one-off variables (see
  [Known gaps](#known-gaps--not-yet-supported)).
- `{{$uuid}}`, `{{$timestamp}}`, etc. (magic variables) are generated
  fresh per request and are not configurable from the CLI invocation.
- There is **no CLI flag to list available environment names** from an
  `http-client.env.json` — the plugin must read and parse that JSON file
  itself if it wants to offer an environment picker (it's a plain JSON
  file with environment names as top-level keys; keys starting with `$`
  are reserved/skipped by `tachy` itself, e.g. `$schema`).

## Exit codes and error surfaces

`tachy` uses exactly two exit codes: `0` (success) and `1` (any failure).
There is no finer-grained exit-code taxonomy (e.g. no distinct code for
"parse error" vs. "network error" vs. "assertion failure") — **the
plugin must inspect stdout/stderr, not the exit code, to distinguish
failure kinds.**

| Situation | stdout | stderr | exit |
|---|---|---|---|
| All requests in all files succeed | Normal output (text or NDJSON) | (nothing) | 0 |
| A request fails (network error, non-2xx isn't itself a failure — only an `@expect-status-code` mismatch is) but others in the file still run | That request's `error` field / `error: ...` line still appears in stdout; other requests still execute and print | `<file>: one or more requests failed` then `tachy: one or more requests failed` | 1 |
| `.http` file fails to parse (via `run`) | (`file_error` JSON object if `--format json`; nothing in text mode) | `parsing <path>: <details>` then, after all files, `tachy: one or more requests failed` | 1 |
| `.http` file fails to parse (via `list`) | (`file_error` JSON object if `--format json`; nothing in text mode) | `parsing <path>: <details>` then, after all files, `tachy: one or more files failed to parse` | 1 |
| Argument path doesn't exist | (nothing) | `tachy: resolving "<path>": stat <path>: no such file or directory` | 1 |
| No `.http` files found under given path(s) | (nothing) | `tachy: no .http files found in [<args>]` | 1 |
| No args given to `run`/`list` | (nothing) | `tachy: requires at least 1 arg(s), only received 0` | 1 |
| `--request <name>` matches nothing anywhere | (nothing) | `tachy: no request named "<name>" found in [<args>]` | 1 |
| `--format <bad>` | (nothing) | `tachy: invalid --format "<bad>": must be "text" or "json"` | 1 |
| Missing `tachy` binary itself | N/A — not a CLI concern | N/A | N/A (the plugin's job: check `vim.fn.executable("tachy")` / equivalent before spawning, and surface a clear "tachy not found on $PATH" error rather than a cryptic spawn failure) |

Every top-level `tachy: ...` line comes from `main.go`'s error handler
(`fmt.Fprintln(os.Stderr, "tachy:", err)`) and is always on **stderr**,
always exactly one line, always prefixed `tachy: `. Per-file failure
detail lines (e.g. `parsing <path>: ...`, `<path>: one or more requests
failed`) are also stderr, printed by `run`/`list` per file **before**
that final summary line — so a `run` over 3 files where file 2 fails to
parse produces up to 2 stderr lines: the per-file parse error, then the
final `tachy: one or more requests failed` summary.

Note the two commands' final summary lines are worded differently —
`run` says `tachy: one or more requests failed`, `list` says `tachy: one
or more files failed to parse` (verified against both commands' actual
output). Neither wording is contractually stable text to pattern-match
on (see the `file_error.error` field note above); this is called out
only so a `list`-then-`run` integration doesn't assume the two share one
summary string. Don't assume stderr
is exactly one line.

## Recommended plugin workflows

**Populate a request picker / "run request under cursor":**

> **`line` pitfall (caused a real bug — read before implementing this):**
> `requestMeta.line` / `request.line` is the 1-based source line of the
> **request line** (the `GET`/`POST`/... line), **not** the `### NAME`
> block-header line — this matches the field table above and
> `httpfile.Request.Line`'s own doc comment in the CLI source. The two
> are frequently *different* lines: a block's own `@var = value`
> preamble, comments, `@directive`s, or a pre-request script can all sit
> between `### NAME` and the request line it belongs to. A previous
> version of this doc described `line` as "the block that starts at or
> before the cursor," which reads as if it were the `###` header line —
> it isn't, and matching against it that way silently resolves the
> **wrong request** (specifically: the request *before* the one the
> cursor is actually on) whenever the cursor sits on or near the `###
> NAME` line itself, with no error to signal the mismatch. `tachy list`
> does **not** currently expose the `###` header's own line number at
> all. If the plugin needs to map "cursor position in the buffer" to
> "which request block," **scan the buffer directly for `###` markers**
> (the plugin already has the buffer text — this doesn't require a
> second parser, just a regex/pattern match on lines starting with three
> or more `#` characters) rather than relying on `tachy list`'s `line`
> field for that specific lookup. Use `tachy list --format json` for
> what it's actually good for: getting the authoritative `name` (and
> `method`/`url` for display) to pass to `--request` once you already
> know which block the cursor is on by your own buffer scan.

1. Scan the current buffer yourself for `###` delimiter lines (`^#{3,}`)
   to determine which block the cursor is inside (the last `###` line at
   or before the cursor; text before the first `###` is the first
   block). Extract the name from that line, if any (the text after
   `###`, trimmed).
2. Cross-check against `tachy list <current-file> --format json` by
   matching on `name` (not `line`) to confirm the request exists and get
   its `method`/`url` for a confirmation UI, if wanted. This step is
   optional — the name from your own buffer scan is already sufficient
   to call `--request` with.
3. To run it: `tachy run <current-file> --request <name>` if the block
   has a `name`. **If it has no name**, `--request` cannot target it —
   fall back to running the whole file, or tell the user to name the
   block.
4. Before using `--request` for a single block, consider whether it
   references `{{OTHER.response...}}` chaining — if so, running the
   whole file (no `--request`) is the only way those placeholders
   resolve; see the `--request` chaining caveat above.

**Run an entire file (e.g. a "run buffer" keybinding):**
- `tachy run <file> --format json [--env <name>]`, spawned async, stdout
  read line-by-line and each line `json.decode`d independently as it
  arrives (safe: each line is a complete, self-contained JSON value).

**Environment picker:**
- No CLI support; read and `json.decode` the nearest
  `http-client.env.json` (and `.private.env.json`, which overrides it)
  the plugin finds walking up from the `.http` file's own directory,
  same algorithm `tachy` itself uses (see
  [Environment / variable selection](#environment--variable-selection)),
  and list its top-level keys minus any starting with `$`.

**Detecting an old `tachy` without `list`/`--format json`/`--request`:**
- `tachy list --help` exits 0 and prints `Usage: tachy list ...` on a
  binary that has it; an older binary without the subcommand exits 1 with
  `tachy: unknown command "list" for "tachy"` on stderr. Check for that
  once (e.g. on plugin setup) rather than on every invocation.

## Known gaps / not yet supported

These are real gaps in the CLI as of this writing. The plugin should
treat them as described, not guess at a different shape:

- **No `--var name=value` flag.** There is no way to inject an ad-hoc
  variable from the command line. Workarounds: write it into the `.http`
  file's `@name = value` header, or into an environment file, or have a
  pre-request Lua script set it (`request.variables.set`). If the plugin
  wants a "run with this one variable overridden" UX, it currently has
  no CLI hook for that — flag it to the user as unsupported rather than
  faking it by rewriting the `.http` file on disk (which would be
  surprising/destructive).
- **No environment-name listing command.** Covered above — read the JSON
  file directly.
- **No dry-run/"resolve variables and show me the request without
  sending" mode.** `list` shows raw unresolved URLs only; there is no way
  to see what a request would look like *after* substitution without
  actually sending it. If the plugin wants a "preview resolved request"
  feature, it isn't supported by the CLI today.
- **Auth helpers (`auth.BasicHeader`/`BearerHeader`/OAuth2) are not
  auto-applied.** They exist as Go library functions but nothing in
  `tachy run` calls them on a request's behalf. A `.http` file must
  already contain a resolved `Authorization` header (literal or via a
  `{{var}}` a script populates). The plugin should not expect any
  special auth UX beyond what's written in the file.
- **No replay.** Re-sending the last request (`$kulala.request.replay()`
  equivalent) isn't implemented. A "repeat last request" plugin feature
  would have to just re-invoke `tachy run --request <name>` itself.
- **No secrets-manager integration** (1Password/KeePassXC subprocess
  pulls) — deferred on the CLI side entirely.
- **gRPC and WebSocket requests are not implemented at all.** `GRAPHQL`
  works (it's just a shaped `POST`); a `.http` file using a gRPC/WS
  syntax the parser doesn't recognize will fail to parse or behave
  unpredictably — don't build UI affordances for these protocols yet.
- **No persistence across invocations.** Chaining/cookies are
  memory-only, scoped to one `tachy run` process. Every plugin-triggered
  run starts cold; there's no `--persist`/session concept to opt into
  today, so "run LOGIN once, then run other requests against it
  individually over multiple separate `tachy` invocations" does **not**
  work — chaining only works within one `tachy run` call across the
  requests in the same file(s).
- **Binary response bodies are treated as raw UTF-8 text in JSON
  output**, with no explicit base64/binary-safe encoding. Sending or
  displaying a binary body (e.g. an image response) via `--format json`
  is not a solved problem in the CLI today — Go's `encoding/json` will
  produce mangled/invalid-UTF-8-escaped output for genuinely binary
  bytes. Avoid relying on `response.body` for binary content; the `>>`/
  `>>!` save-to-file directive (written into the `.http` file itself, not
  a CLI flag) is the only tested path for binary responses today.
- **No structured "which files were discovered" output** independent of
  parsing them — `tachy list <dir>` both discovers *and* parses; if a
  plugin just wants "what `.http` files exist under this directory" it
  has to derive that from `list`'s `file` fields (and tolerate
  `file_error` entries for files that don't parse) rather than a
  dedicated discovery-only command.
- **`docs/usage.md` in the `tachydromos` repo has one stale claim** (env
  resolution "walked upward from the working directory") — see
  [Environment / variable selection](#environment--variable-selection).
  Trust this contract doc and the verified behavior over that line until
  it's corrected upstream.

## Command/flag summary table

| Command | Flags | Purpose |
|---|---|---|
| `tachy version` | — | Print `tachy <version>`, exit 0. |
| `tachy list <file\|dir>...` | `--format text\|json` (default `text`) | Enumerate requests without executing. No env resolution, no network I/O. |
| `tachy run <file\|dir>...` | `--env <name>`, `--format text\|json` (default `text`), `--request <name>` | Execute requests. Blocking; use an async job from the plugin. |
| (root, persistent) | `--dir <path>` | Base dir for resolving relative file/dir arguments only — not env-file discovery. |

All three commands accept one or more file/directory arguments;
directories are walked recursively for `*.http` files (extension match
only, case-sensitive `.http`). File arguments are taken as given even
without a `.http` extension. Given paths are deduplicated and files are
processed in sorted order.

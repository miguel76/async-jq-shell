# async-jq-shell

An experiment in running **asynchronous jq filters**: a filter, instead of
returning its output directly, can return a description of the actions to run
next (e.g. shell commands) and of the filter that will process their output.

This repository contains:

- [`SPEC.md`](SPEC.md): the async-jq specification, i.e. the step format and
  its meaning, independent of any implementation;
- `async-jq`: an engine implementing it in POSIX `sh` and jq (the `-shell`
  in the name leaves room for other implementations);
- [`tests/`](tests/): a test suite, usable to check any implementation.

```jq
# flow/main.jq: count the lines of a file, then describe the count
include "async-jq";
{
    action: "wc -l < \("data/input.txt" | resolve_file | @sh)",
    sync_next: "./describe"       # flow/describe.jq: "\(.) lines"
}
```

```bash
$ async-jq main
"3 lines"
```

## Requirements

A POSIX `sh` (e.g. `dash`, `bash`, `zsh`), [jq](https://jqlang.github.io/jq/)
1.7, and the usual POSIX utilities (`mktemp`, `readlink`, `sed`, `cat`, ...).

## Installation

No build is needed: run `bin/async-jq` from a clone of this repository. To
have it in your `PATH`, link it (the engine finds its `lib/` directory through
the link):

```bash
ln -s "$PWD/bin/async-jq" ~/.local/bin/async-jq
```

In a project, it can be installed with [jqpm](https://github.com/miguel76/jqpm),
which links the command as `jq_modules/.bin/async-jq`:

```bash
jqpm add miguel76/async-jq-shell
jqpm exec async-jq main          # or: jq_modules/.bin/async-jq -L jq_modules main
```

`jqpm exec` sets `JQ_LIBRARY_PATH` to `jq_modules`, so that the filters can
also import the other packages installed with jqpm (see the `-L` option
below).

Or it can be added as a git submodule, pinned to a release:

```bash
git submodule add https://github.com/miguel76/async-jq-shell vendor/async-jq-shell
vendor/async-jq-shell/bin/async-jq main
```

## Usage

```
async-jq [--input JSON | --stdin] [--args JSON] [--envelope] [-L DIR]... <filter>
```

Calls `<filter>` and executes the steps it returns (see [`SPEC.md`](SPEC.md)).
The filter reference is resolved as in a `call` step: `main` is
`$FLOW_PATH/main.jq` (or `$FLOW_PATH/main/main.jq`), `./x/y` is `x/y.jq` (or
`x/y/y.jq`) relative to the current directory.

On success it prints the final result (as JSON) on stdout and exits with 0.
On failure it prints `Error: ...` on stderr and exits with 1. Debug messages
of the filters go to stderr.

| Option | Meaning |
|---|---|
| `--input JSON` | the input of the filter (default: `null`) |
| `--stdin` | read the input of the filter (exactly one JSON value) from stdin |
| `--args JSON` | named arguments for the filter (an object, as `args` in a `call` step) |
| `--envelope` | print the final outcome as an envelope, `{"result": ...}` or `{"error": ...}`, on stdout (the exit status is still 1 on error) |
| `-L DIR`, `--library-path DIR` | add `DIR` to the jq search path of the filters, as jq's `-L` (can be repeated) |
| `-h`, `--help` | show the help |

For example:

```bash
echo '{"x": 1}' | async-jq --stdin --args '{"verbose": true}' ./my-flow
```

Configuration, through environment variables (relative to the current
directory):

| Variable | Default | Meaning |
|---|---|---|
| `FLOW_PATH` | `flow` | root of the application's filters |
| `DATA_PATH` | `.` | root of the application's data files |
| `JQ_LIBRARY_PATH` | | colon-separated directories added to the jq search path of the filters, after the `-L` ones (directories that don't exist are skipped); set by `jqpm exec` |

## Implementation notes

### Shell steps

- The command runs with `eval` in the engine's shell, in the directory where
  `async-jq` was started: use `resolve_file` to pass it absolute paths.
- Its stdin and stderr are those of `async-jq`. It does not receive the
  step's input.
- Its stdout is captured with a command substitution, which removes trailing
  newlines.
- A newline is added after the command, so a trailing `# comment` can't
  swallow the rest of the generated script.

### Command-line size limits

Data that can be large (steps, inputs, results, error messages) is always
passed to `jq` on stdin or embedded in the generated script, never as a
command-line argument, so it is not subject to the operating system's limit
on the size of an argument (128 KB on Linux). The only exception is `args`,
passed to the filters as `--argjson`.

### Engine context

The engine passes its context to the filters it runs as
`--argjson engine_context '{"base": <directory of the filter>, "config": {...}}'`,
and runs them with the jq search path: `lib/` (so that `include "async-jq";`
always finds the engine's library), then the `-L` directories, then
`JQ_LIBRARY_PATH`, then jq's default search path.

### Files

- `bin/async-jq`: entry point. Computes the configuration and executes
  `{"call": "<filter>", "input": ..., "args": ...}`.
- `lib/to-shell.jq`: translates a step into a POSIX shell script. It first
  normalizes the step (desugaring, resolving references), then translates
  it. The script for any step reads the step input from the shell variable
  `$__in` and prints exactly one JSON *envelope* on stdout, `{"result": X}`
  or `{"error": E}`. When a filter returns a step, the engine translates it
  with `to-shell.jq` again, at execution time.
- `lib/async-jq.jq`: the async-jq library, used by both `to-shell.jq` and
  the filters. Reference resolution is implemented in a single place there
  (`_resolve`), meant to be extended with more complete mechanisms for
  modular development.

## Tests

```bash
tests/run.sh            # all the cases
tests/run.sh lookup     # the cases whose name contains "lookup"
```

The cases are in `tests/cases.json` (the format is described in
`tests/run.sh`), with their filters in `tests/flow/` and data in
`tests/data/` (and jq modules for the `-L` cases in `tests/modules/`). To test another implementation of the spec, set `ASYNC_JQ` to
its command, which must accept the options above, including `--envelope`.

## Possible improvements

- Pass the step input to shell commands on stdin, with an input format
  (`json`, compact or not, `text` for strings, `none`), and also as an
  environment variable or argument.
- A `bytes` format (base64-encoded string) for binary data, in both
  directions.
- A `json_seq` (or `lines`) format, giving an array of the JSON values (or
  lines) in the output.
- Keep trailing newlines in shell output in `text` format (output through a
  temporary file instead of a command substitution).
- Choose the default format from the file extension (`.json` as `json`,
  others as `text`) or, for URLs, from the response's content type.
- Capture the stderr of failing shell commands into the error, as is done for
  filters.
- Remote files for `fetch_file` (with `curl`), and caching.
- Module references (`module:path`) and search paths for filters and data
  files.

## License

GPL-2.0, see [`LICENSE`](LICENSE).

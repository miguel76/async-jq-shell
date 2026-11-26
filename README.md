# async-jq-shell

An engine for **async-jq flows**: JSON descriptions of dataflow pipelines,
whose building blocks run shell commands, read and write files, evaluate
[jq](https://jqlang.github.io/jq/) filters, and run other flows, including
flows computed at run time by jq filters.

This repository contains:

- [`SPEC.md`](SPEC.md): the async-jq specification, i.e. the flow format and
  its meaning, independent of any implementation;
- `async-jq`: an engine implementing it in POSIX `sh` and jq (the `-shell`
  in the name leaves room for other implementations);
- [`tests/`](tests/): a test suite, usable to check any implementation.

```json
{
  "type": "Cascade",
  "subflows": [
    {"type": "Shell", "cmd": "wc -l"},
    {"type": "Jq", "filter_code": "\"\\(.) lines\""}
  ]
}
```

```bash
$ printf 'a\nb\nc\n' | jq -Rs . | async-jq --stdin count.json
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
jqpm add miguel76/async-jq-shell@^0.2.0
jqpm exec async-jq flow.json      # or: jq_modules/.bin/async-jq -L jq_modules flow.json
```

`jqpm exec` sets `JQ_LIBRARY_PATH` to `jq_modules`, so that the jq filters
run by the flows can also import the other packages installed with jqpm (see
the `-L` option below).

## Usage

```
async-jq [--input JSON | --stdin] [--named NAME=JSON]... [--envelope] [-L DIR]... (<flow.json> | --flow JSON)
```

Runs the flow in the flow document `<flow.json>` (relative paths in it being
relative to the document's directory), or the flow given with `--flow`
(relative paths being relative to the current directory).

On success it prints the result (as JSON) on stdout and exits with 0. On
failure it prints `Error: ...` on stderr and exits with 1. Debug messages of
the jq filters go to stderr.

| Option | Meaning |
|---|---|
| `--flow JSON` | the flow to run, given in place of a flow document |
| `--input JSON` | the input of the flow (default: `null`) |
| `--stdin` | read the input of the flow (exactly one JSON value) from stdin |
| `--named NAME=JSON` | bind the named input `NAME` (can be repeated) |
| `--envelope` | print the outcome as an envelope, `{"result": ...}` or `{"error": ...}`, on stdout (the exit status is still 1 on error) |
| `-L DIR`, `--library-path DIR` | add `DIR` to the jq search path of the filters, as jq's `-L` (can be repeated) |
| `-h`, `--help` | show the help |

| Environment variable | Meaning |
|---|---|
| `JQ_LIBRARY_PATH` | colon-separated directories added to the jq search path of the filters, after the `-L` ones (directories that don't exist are skipped); set by `jqpm exec` |

### Writing flows in jq

Flows are plain JSON, so they can also be computed by jq filters (run with a
`Jq` flow, then an `Exec`), using the constructors of the async-jq library:

```jq
import "async-jq" as aj;
aj::cascade([
    aj::fetch("./data.json"),          # paths are made absolute
    aj::for_each(aj::jq_ref("./item.jq"); true; true)
])
```

See [`SPEC.md`](SPEC.md) for the operators and the library.

## Implementation notes

### How flows run

- `lib/to-shell.jq` checks a whole flow (an invalid flow fails with a `flow`
  error before anything runs) and compiles it into POSIX shell code: the
  composition and control operators become shell structure, and the other
  operators calls to the functions in `lib/runtime.sh`.
- Each compiled flow reads its input as JSON text from the shell variable
  `$__in`, and its named inputs from a JSON *scope file* (whose path is in
  `$__scope`); it prints the value of its outcome and exits with status 0
  for a result, 1 for an error.
- `Exec` loads (or reads from its named input `flow`) a flow and compiles it
  at run time.
- `Parallel` and parallel `ForEach` run their subflows as background jobs,
  and collect their outcomes from files.
- Temporary files (scope files, `MakeFile` without a location, ...) live in
  a directory removed at the end of the run.

### Shell commands

- The command runs with `eval`, in a subshell of the engine, in the
  directory where `async-jq` was started: use `resolve_file` in jq filters to
  build absolute paths.
- Its stdin is the flow's input (serialized according to `input_format`), or
  `/dev/null` if the input is `null`. Its stderr is the engine's.
- Its stdout is captured with a command substitution, which removes trailing
  newlines.

### jq filters

- Filters run with the jq search path: `lib/` (so that
  `import "async-jq" as aj;` always finds the library), then the `-L`
  directories, then `JQ_LIBRARY_PATH`, then jq's default search path.
- Named inputs are bound as `$name` variables with `--argjson` when their
  JSON text is at most 100 KB, up to 1 MB in total (command-line arguments
  are limited in size); all of them are available through
  `aj::named_input(name)`, which reads them from a file. The library gets its
  context (the filter's directory and the named inputs) as
  `--slurpfile __async_jq <file>`.

### Command-line size limits

Data that can be large (flows, inputs, results, named inputs, error
messages) is passed to `jq` on stdin or through files, never as a
command-line argument, so it is not subject to the operating system's limit
on the size of an argument (128 KB on Linux). The only exceptions are the
named inputs bound as `$name` variables (see above) and the options given to
`async-jq` itself.

## Tests

```bash
tests/run.sh            # all the cases
tests/run.sh parallel   # the cases whose name contains "parallel"
```

The cases are in `tests/cases.json` (the format is described in
`tests/run.sh`), with their filters in `tests/filters/`, flow documents in
`tests/flows/`, data in `tests/data/` and jq modules (for the `-L` cases) in
`tests/modules/`. To test another implementation of the spec, set `ASYNC_JQ`
to its command, which must accept the options above, including `--envelope`.

## Possible improvements

- `FunctionCall`, functions and modules (see SPEC.md, "Future extensions").
- Module references in paths (e.g. to packages installed with jqpm), and
  remote resources (URLs) for `Fetch` and `Exec`.
- A `bytes` format (base64-encoded strings) for binary data, `json_seq` and
  `lines` formats.
- Named inputs for shell commands (e.g. as environment variables).
- Capturing the stderr of failing shell commands into the error, as is done
  for jq filters.
- Running the assignments of a `Let` concurrently (the spec allows it; they
  currently run in order).
- A limit on the number of concurrent jobs for `Parallel` and `ForEach`.

## License

GPL-2.0, see [`LICENSE`](LICENSE).

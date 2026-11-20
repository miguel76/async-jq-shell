# async-jq specification

*Draft, version 0.1.*

**async-jq** is a way of writing programs as **asynchronous jq filters**: a
filter, instead of returning its output directly, can return a description of
what to do next (run a shell command, read a file, call another filter, ...)
and of how to process the outcome. An *engine* executes these descriptions.

This document describes the format of these descriptions and their meaning,
independently of any implementation. [`async-jq-shell`](README.md) is an
implementation based on POSIX `sh`. The test suite in [`tests/`](tests/)
checks an implementation against this specification.

## Filters

Filters are jq programs, in `.jq` files. There are two kinds:

- **asynchronous filters** output a *step* (described below): what to do
  next. They are run by `call` and `next`.
- **synchronous filters** are ordinary jq filters: they directly output their
  result, or raise an error. They are run by `sync_call` and `sync_next`.

Both get as input the input of the step that runs them, and may get named
arguments (see [Arguments](#arguments)).

Filters run by the engine can use the [async-jq library](#library) with
`include "async-jq";`.

## Steps

A step describes something to execute. Executing a step takes an input (a
JSON value) and produces an *outcome*: either a result (a JSON value) or an
error (a JSON value).

A step is either a string, an array or an object. A string `"cmd"` is a
shorthand for `{"shell": "cmd"}`. An array `[s1, s2, ...]` executes the steps
in sequence, all with the same input; its result is the array of their
results.

An object step has at most one **main field**, saying what the step does:

| Main field | Result |
|---|---|
| `"result": X` | `X` |
| `"error": E` | fails with error `E` |
| `"shell": "cmd"` | the output of shell command `cmd` (see [Data formats](#data-formats)) |
| `"fetch_file": "ref"` | the content of the data file `ref` (see [Data formats](#data-formats)) |
| `"call": "ref"` | runs the asynchronous filter `ref` on the input, then executes the step it returns (with `null` input, see [Inputs](#inputs)); the result is that step's result |
| `"sync_call": "ref"` | the output of the synchronous filter `ref` run on the input |
| `"action": S` | the result of step `S`, executed with the same input |
| *(none)* | the input itself |

and optionally these fields:

| Field | Meaning |
|---|---|
| `"input": X` | the step's input is `X`, instead of the one it would get (see [Inputs](#inputs)) |
| `"args": {...}` | for `call` and `sync_call`: named arguments for the filter (see [Arguments](#arguments)) |
| `"next": N` | then execute step `N` with the result as input; the result of `N` is the result of the whole step |
| `"sync_next": "ref"` | shorthand for `"next": {"sync_call": "ref"}` |
| `"on_error": H` | if the main part of the step fails with error `E`, execute step `H` with `E` as input; its outcome replaces the failed one (see [Error handling](#error-handling)) |
| `"format": "auto" \| "json" \| "text"` | for `shell` and `fetch_file`: how to parse the output (default `auto`) |

In `next` and `on_error`, a string is a reference to an asynchronous filter
(i.e. `"next": "ref"` is `"next": {"call": "ref"}`), not a shell command.

A step is invalid, and fails with a `step` error, if it has unknown fields,
more than one main field, both `next` and `sync_next`, `input` together with
`result` or `error`, `args` without `call` or `sync_call`, or `format`
without `shell` or `fetch_file`.

A filter that outputs several steps is equivalent to one that outputs the
array of them.

A step's main part is always completed before its `next` starts, since its
outcome decides whether `next` runs at all.

### Inputs

The input of a step comes from where the step is:

| Step | Input |
|---|---|
| the step run by the engine at the start | `null`, unless the engine is given an input |
| a step returned by a filter | `null` |
| `action`, array elements | the input of the enclosing step |
| `next` | the result of the main part of the enclosing step |
| `on_error` | the error |

A step returned by a filter is thus self-contained: any data it needs is in
the step itself. To give a step a specific input, use the `input` field:

```jq
{call: "./g", input: .records, next: "./h"}
```

`{"input": X, ...rest}` is a shorthand for `{"result": X, "next": {...rest}}`:
the step's own `next` and `on_error` apply to `rest`, as usual.

Note that `input` replaces the input the step would otherwise get: in
`{"action": A, "next": {"call": "g", "input": X}}` the result of `A` is
discarded.

### Arguments

Besides their input (the data flowing through the pipeline), filters can be
given named arguments, meant for parameters (configuration, options, names,
...), with `args`:

```jq
{call: "./generate-rule", args: {rule: "subclass"}, input: .bindings}
```

The filter gets each entry as a jq variable (`$rule`) and in
`$ARGS.named`, as if run with `jq --argjson name value`. Names must be valid
jq variable names; `engine_context`, `ENV`, `ARGS` and names starting with
`__` are reserved. A filter using a variable that it is not given fails.

Arguments are meant to be small; large data should be passed as input.

### `call` and `next`

`{"call": "f", "next": N}` runs `f` and then `N`. Rather than waiting for the
step returned by `f` to complete and then running `N`, the engine **inserts
`N` into the step returned by `f`**, before executing it, as its `next`:

- if the returned step has no `next`, `N` becomes its `next`;
- otherwise `N` is inserted (in the same way) in its `next`, so it ends up in
  the first step without `next` of the `.next.next...` chain;
- an array is first wrapped as `{"action": [...]}`.

So the continuation is passed down from call to call. This is equivalent to
running the returned step and then `N`, because `on_error` only covers the
main part of a step, never its `next`: a handler in the called filter never
catches errors raised by the caller's continuation. (For the same reason, when
the `call` step itself has an `on_error`, `N` is not inserted but simply run
afterwards.)

### Example

A filter returning:

```json
[
  {"call": "subclass", "args": {"query": "/app/flow/query"}},
  {"result": "CONSTRUCT WHERE {?s ?p ?o}"}
]
```

calls `subclass` (found as `subclass.jq` or `subclass/subclass.jq`, see
[Filter lookup](#filter-lookup)), which may return:

```json
{"input": "/app/flow/subclass/relation.rq", "call": "/app/flow/query", "sync_next": "./rule"}
```

`query` gets the path of a SPARQL query as input and returns the command to
run it (a string, i.e. a shell step); the command's JSON output is passed to
the synchronous filter `subclass/rule.jq`, which outputs a string. The
results of the array's elements are collected: the final result is an array
of two strings.

## References to files

`call`, `sync_call`, `next`, `sync_next` and `on_error` refer to filters;
`fetch_file` and `resolve_file` refer to data files. References are resolved
to absolute paths:

| Reference | Resolved against |
|---|---|
| `./path`, `../path` | the directory of the filter that returned the step (the current filter) |
| `/path` | nothing: already absolute |
| `path` | the application root: the *flow path* for filters, the *data path* for data files (configured in the engine) |
| `scheme://...` | a URL: kept as it is (invalid for filters) |

The engine resolves all the references in a step as soon as it gets it, so
the step can be moved to another filter's context (e.g. a `next` inserted by
a `call`) without changing meaning.

Further kinds of references (e.g. `module:path` references to modules
registered in the configuration, or search paths) may be added in future
versions.

### Filter lookup

Filter references follow jq's convention for modules: `foo/bar` is the file
`foo/bar.jq` or, if it doesn't exist, `foo/bar/bar.jq`. So a filter can live
in a directory with the same name, together with the files it uses:

```
flow/subclass/subclass.jq    # {"call": "subclass"}
flow/subclass/relation.rq    # "./relation.rq" from subclass.jq
flow/subclass/rule.jq        # "./rule" from subclass.jq
```

A reference ending in `.jq` is that file only. `./` references in a filter
(and in the steps it returns) are relative to the directory of the file
actually found.

Since jq can't check whether a file exists, references are resolved to
absolute references without the extension, and the file is chosen when the
filter is run. If no candidate exists, the step fails with a `filter` error
listing the `candidates`.

## Data formats

The `shell` and `fetch_file` steps turn bytes into a JSON result according to
their `format`:

| Format | Result |
|---|---|
| `auto` (default) | parsed as JSON if it is a single JSON value; otherwise the text, as a string; the empty string if empty |
| `json` | parsed as JSON; fails with a `parse` error if not valid |
| `text` | the text, as a string |

- `shell`: the command's standard output, with trailing newlines removed. A
  command that exits with a non-zero status fails. The command does not
  receive the step's input.
- `fetch_file`: the file's content, as it is.

## Error handling

Errors are values. Every step produces either a result or an error, and
errors are caught where they happen:

| Cause | Error |
|---|---|
| an `error` step | its value |
| a shell command fails | `{"type": "shell", "command", "status"}` |
| a filter is not found | `{"type": "filter", "filter", "message", "candidates"}` (`candidates`: the files tried) |
| a filter fails (jq compile or runtime error, ...) | `{"type": "filter", "filter", "status", "message"}` (`message`: jq's error output) |
| a synchronous filter outputs zero or several values | `{"type": "sync_call", "filter", "message"}` |
| a file can't be fetched | `{"type": "fetch", "file", "message"}` |
| a file can't be parsed in the requested format | `{"type": "parse", "format", "message"}` |
| an invalid step | `{"type": "step", "message", "step"}` |

By default, errors propagate:

- if the main part of a step fails, its `next` is **not** executed and the
  whole step fails with that error;
- in an array, all steps are executed; if any of them failed, the whole array
  fails with the first error.

### `on_error`

```json
{"action": "arq ...", "on_error": "./handle-error", "next": "./process"}
```

If the main part of the step fails with error `E`, the handler (here the
filter `handle-error`, but it can be any step) is executed with `E` as input,
and its outcome replaces the failed one: a result is then passed to `next`.
The handler can for example:

- recover with a fallback value: `{result: []}`
- re-raise, possibly adding context: `{error: {while: "querying", cause: .}}`
- retry or try an alternative: `"arq ... --query=..."`

If the main part succeeds, the handler is not executed. If the handler itself
fails, its error propagates as usual. The handler doesn't cover `next`: to
also handle errors raised there, wrap the step:
`{"action": {"action": ..., "next": ...}, "on_error": ...}`.

## Library

Filters run by the engine can `include "async-jq";` to use:

| Function | Result |
|---|---|
| `resolve_file`, `resolve_file(ref)` | the absolute path of data file `ref` (or of the input reference) |
| `resolve_filter`, `resolve_filter(ref)` | the absolute reference to filter `ref`, usable in steps (without `.jq`: the file is chosen at execution time, see [Filter lookup](#filter-lookup)) |
| `filter_candidates`, `filter_candidates(ref)` | the files that may hold filter `ref`, in lookup order |

References are resolved as described in
[References to files](#references-to-files), `./` being relative to the
filter run by the engine (not to the module calling the function). This is
useful to pass absolute paths to shell commands, e.g.

```jq
include "async-jq";
{action: "cat \("./data.csv" | resolve_file | @sh)", next: "./parse"}
```

The engine gives the library its context through the named argument
`engine_context`.

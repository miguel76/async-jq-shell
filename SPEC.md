# async-jq specification

*Draft, version 0.2.*

**async-jq** is a way of writing programs as **flows**: JSON descriptions of
dataflow pipelines, whose building blocks run shell commands, read and write
files, evaluate [jq](https://jqlang.github.io/jq/) filters and run other
flows, including flows computed at run time. An *engine* executes them.

This document describes flows and their meaning, independently of any
implementation. [`async-jq-shell`](README.md) is an implementation based on
POSIX `sh` and jq. The test suite in [`tests/`](tests/) checks an
implementation against this specification.

Changes from version 0.1 are summarized at the [end](#changes-from-version-01).

## Overview

A **flow** is a JSON object with a `type` field naming its **operator**, and
further fields depending on the operator:

```json
{
  "type": "Cascade",
  "subflows": [
    {"type": "Shell", "cmd": "wc -l < data.txt"},
    {"type": "Jq", "filter_code": "\"\\(.) lines\""}
  ]
}
```

Evaluating a flow takes:

- an **input**: a JSON value;
- **named inputs**: a mapping from names to JSON values (the *scope*);
- a **base**: the directory against which relative paths in the flow are
  resolved (see [Paths](#paths));

and produces an **outcome**: either a **result** (a JSON value) or an
**error** (a JSON value).

In the following, "the input" and "the named inputs" of a flow are those it
is evaluated with, and a flow "returns" its result or "fails" with its error.
Unless stated otherwise, an operator evaluates its subflows with its own
input, named inputs and base, and fails with the first error of a subflow it
evaluates, without evaluating any further subflow.

## Flow documents

A **flow document** is a file holding a flow as JSON. The base of the flows
it contains is the directory of the file.

A flow is **invalid** if its `type` is missing or unknown, if it has a field
that its operator doesn't define, if a required field is missing, or if a
field has the wrong type. Evaluating an invalid flow fails with a `flow`
error (see [Errors](#errors)). Whether an engine checks a whole flow before
evaluating it, or each flow when evaluating it, is implementation-defined.

## Operators

### Values

| Flow | Result |
|---|---|
| `{"type": "Constant", "data": X}` | `X` |
| `{"type": "Identity"}` | the input |
| `{"type": "Get", "input_id": "x"}` | the named input `x`; fails with an `input` error if there is none |
| `{"type": "Error", "error": E}` | fails with error `E` |

### Composition

**Cascade**: `{"type": "Cascade", "subflows": [F1, ..., Fn]}`

Evaluates `F1`, ..., `Fn` in order: `F1` with the input of the Cascade, each
following one with the result of the previous one. Returns the result of
`Fn`. With no subflows, returns the input.

**Sequence**: `{"type": "Sequence", "subflows": [F1, ..., Fn]}`

Evaluates `F1`, ..., `Fn` in order, each with the input of the Sequence.
Returns the array of their results, in order. With no subflows, returns `[]`.

**Parallel**: `{"type": "Parallel", "subflows": [F1, ..., Fn], "preserve_order": B}`

Evaluates `F1`, ..., `Fn`, each with the input of the Parallel, in any order,
possibly concurrently. Returns the array of their results:

- in the order in which their evaluations completed, which is unspecified,
  if `preserve_order` is `false` (the default);
- in the order `F1`, ..., `Fn`, if `preserve_order` is `true`.

If some subflows fail, all the subflows are still evaluated, and the Parallel
fails with the error of the first failed subflow in the order `F1`, ...,
`Fn`. With no subflows, returns `[]`.

### Named inputs

**Let**: `{"type": "Let", "assign": {"x1": A1, ..., "xn": An}, "subflow": F}`

Evaluates `A1`, ..., `An`, each with the input and named inputs of the Let,
in any order (possibly concurrently). Then evaluates `F` with the input of the
Let and its named inputs extended with `x1`, ..., `xn` bound to the results
of `A1`, ..., `An`, replacing any outer binding of the same names. Returns
the result of `F`.

Since all the assigned flows see only the outer named inputs, an assigned
flow that needs another assignment is written with nested Lets. If some
assigned flows fail, the Let fails with the error of the first one in the
lexicographic order of their names.

Named inputs are available to all the flows nested in the Let's subflow,
whatever their depth: the operators below pass them to their subflows,
except where stated otherwise.

Names must be valid jq variable names (`[A-Za-z_][A-Za-z0-9_]*`), other than
`ENV` and `ARGS`, and not starting with `__` (reserved for engines).

### Control

**If**: `{"type": "If", "condition": C, "then": T, "else": E}`

Evaluates `C` with the input. If its result is true (any value other than
`false` and `null`, as in jq), evaluates `T` with the input, otherwise `E`
(by default, an Identity). Returns the result of the branch evaluated.

**Switch**: `{"type": "Switch", "cases": [{"when": C1, "do": D1}, ...], "default": D}`

Evaluates `C1`, `C2`, ... in order, with the input, until one returns a true
value; then evaluates the corresponding `D` with the input. If none does,
evaluates `D` (by default, an Identity). Returns the result of the flow
evaluated.

**Try**: `{"type": "Try", "subflow": F, "catch": H}`

Evaluates `F`. If it fails with error `E`, evaluates `H` with input `E` and
returns its outcome; the handler can recover (returning a result), re-raise
the error (possibly adding context), or try an alternative. Otherwise,
returns the result of `F`.

**ForEach**: `{"type": "ForEach", "subflow": F, "parallel": P, "preserve_order": B}`

The input must be an array (otherwise, fails with a `type` error). Evaluates
`F` with each of its elements as input, and returns the array of the
results:

- if `parallel` is `false` (the default), in order, as a Sequence;
- if `parallel` is `true`, in any order, possibly concurrently, as a
  Parallel (`preserve_order` having the same meaning and default).

**Loop**: `{"type": "Loop", "while": C, "subflow": F}`

Starting from the input as the current value: evaluates `C` with the current
value; if the result is true, evaluates `F` with the current value, whose
result becomes the new current value, and repeats. Returns the current value
once `C` returns a false value. A Loop whose condition never becomes false
doesn't terminate.

### External resources

**Shell**: `{"type": "Shell", "cmd": "...", "input_format": I, "format": O}`

Runs the shell command `cmd`. Its standard input is the input of the Shell,
serialized according to `input_format` (see [Data formats](#data-formats)),
or is empty if the input is `null`. Returns its standard output, parsed
according to `format`. If the command exits with a non-zero status, fails
with a `shell` error.

Named inputs are not given to the command. Its working directory is the one
in which the engine was started; paths given to it should be absolute (see
the library's `resolve_file`).

**Fetch**: `{"type": "Fetch", "location": "path", "format": O}`

Reads a file and returns its content, parsed according to `format`. The
file is `location` if given, otherwise the input of the Fetch, which must be
a string. Its path is resolved as described in [Paths](#paths). Fails with a
`fetch` error if the file can't be read.

**MakeFile**: `{"type": "MakeFile", "location": "path", "input_format": I}`

Writes the input of the MakeFile, serialized according to `input_format`, to
a file, and returns the file's absolute path. The file is `location` if
given, otherwise the named input `location` if there is one (a string),
otherwise a new temporary file, which exists until the end of the engine's
run. The path is resolved as described in [Paths](#paths); an existing file
is overwritten. Fails with a `make_file` error if the file can't be written.

Note that, being an ordinary named input, a `location` bound by a Let is seen
by all the MakeFile flows within it: keep such a Let tight around the
MakeFile it is meant for, or use the `location` field.

### jq filters

**Jq**: `{"type": "Jq", "filter_ref": "path"}` or `{"type": "Jq", "filter_code": "..."}`

Evaluates a jq filter, given either as the path of a file (`filter_ref`) or
as its source (`filter_code`), with the input of the Jq as input. The filter
must output exactly one value, which is the result of the Jq; zero or
several outputs make the Jq fail with a `jq` error, as does an error raised
by the filter or a filter that doesn't compile.

The named inputs are available to the filter:

- as variables: a named input `x` is `$x`, and all of them are in
  `$ARGS.named`. An implementation may limit the size of the values bound as
  variables, failing with a `jq` error beyond it; it must allow at least
  100 KB per value;
- through the library function `named_input("x")`, with no size limit (see
  [Library](#library)).

A filter referring to a variable that is not bound fails to compile.

The search path of the filter for `import` and `include` starts with the
directory holding the [library](#library), and may be extended by the
engine's configuration. Paths used by the filter through the library
(`resolve_file`) are relative to the directory of the filter's file for a
`filter_ref`, and to the base of the Jq for a `filter_code`.

### Running flows

**Exec**: `{"type": "Exec", "flow_ref": "path"}`, `{"type": "Exec", "flow": F}` or `{"type": "Exec"}`

Evaluates a flow with the input of the Exec, and returns its outcome. The
flow is:

- with `flow_ref`: the flow in the flow document at that path; its base is
  the document's directory;
- with `flow`: the flow `F` given in place; its base is the base of the Exec;
- otherwise: the value of the named input `flow`, which must be a flow
  object; its base is the base of the Exec.

The flow is evaluated with the named inputs of the Exec, except `flow`.

Exec and Jq thus share their scope with the flow or filter they run. A flow
computed at run time typically comes from a Jq filter, whose library
functions resolve the paths it puts in the flow to absolute paths (see
[Library](#library)), so that they don't depend on where the flow is
executed.

**FunctionCall**: reserved, see [Future extensions](#future-extensions).

## Paths

Paths, in the fields `filter_ref`, `flow_ref` and `location`, and in the
inputs of Fetch and MakeFile, are file paths:

- an absolute path is used as it is;
- a relative path (`data.txt`, `./data.txt`, `../data/x.json`) is relative
  to the base of the flow using it.

Paths with a URL scheme (`https://...`) are reserved for remote resources;
engines that don't support them fail with a `fetch` error.

Paths name files exactly: no extension is added, and no other location is
searched.

## Data formats

Values are turned into text (the standard input of Shell, the content
written by MakeFile) according to an **input format**:

| `input_format` | Text |
|---|---|
| `auto` (default) | a string as it is; any other value as JSON |
| `json` | the value as JSON |
| `text` | the value, which must be a string, as it is (otherwise, a `type` error) |

and text (the output of Shell, the content read by Fetch) into values
according to an **output format**:

| `format` | Value |
|---|---|
| `auto` (default) | parsed as JSON if it is a single JSON value; otherwise the text, as a string; the empty string if empty |
| `json` | parsed as JSON; fails with a `parse` error if not valid |
| `text` | the text, as a string |

The output of a Shell has its trailing newlines removed; the content read by
Fetch is used as it is.

## Errors

Errors are JSON values. The errors raised by the engine are objects with a
`type` field and further fields describing them:

| Type | Raised when | Fields |
|---|---|---|
| `flow` | a flow is invalid | `message`, `flow` |
| `input` | a Get refers to an unbound named input | `input_id` |
| `type` | a value has the wrong type (e.g. the input of a ForEach) | `message` |
| `shell` | a shell command fails | `cmd`, `status` |
| `fetch` | a file can't be read | `location`, `message` |
| `make_file` | a file can't be written | `location`, `message` |
| `parse` | a text can't be parsed in the requested format | `format`, `message` |
| `jq` | a jq filter fails to compile, raises an error, or doesn't output exactly one value | `filter`, `message` |

Implementations may add fields. Errors raised with an Error flow, and those
re-raised by a Try's handler, are whatever value they give.

## Library

Filters can use the async-jq library, a jq module:

```jq
import "async-jq" as aj;
```

Importing it (rather than including it) is recommended, so that the uses of
its functions are visible as such (`aj::shell(...)`).

### Paths and named inputs

| Function | Result |
|---|---|
| `resolve_file`, `resolve_file(path)` | the absolute path of `path` (or of the input), relative to the directory of the filter's file (or the base of the Jq, for a `filter_code`) |
| `named_input(name)` | the value of the named input `name`; an error if there is none |

### Flow constructors

Functions returning flows, for filters that compute flows to run with Exec.
Their arguments are flows, values or paths; the paths they put in the flows
are resolved with `resolve_file`, so that the flows can be executed anywhere.

| Function | Flow |
|---|---|
| `constant(data)` | `{"type": "Constant", "data": data}` |
| `identity` | `{"type": "Identity"}` |
| `get(id)` | `{"type": "Get", "input_id": id}` |
| `error(e)` | `{"type": "Error", "error": e}` |
| `cascade(flows)` | `{"type": "Cascade", "subflows": flows}` |
| `sequence(flows)` | `{"type": "Sequence", "subflows": flows}` |
| `parallel(flows)`, `parallel(flows; preserve_order)` | `{"type": "Parallel", ...}` |
| `let(assign; flow)` | `{"type": "Let", "assign": assign, "subflow": flow}` |
| `if_then_else(c; t; e)`, `if_then(c; t)` | `{"type": "If", ...}` |
| `switch(cases; default)`, `switch(cases)` | `{"type": "Switch", ...}`, `cases` being an array of `{when, do}` |
| `try_catch(flow; handler)` | `{"type": "Try", ...}` |
| `for_each(flow)`, `for_each(flow; parallel; preserve_order)` | `{"type": "ForEach", ...}` |
| `loop(condition; flow)` | `{"type": "Loop", ...}` |
| `shell(cmd)`, `shell(cmd; options)` | `{"type": "Shell", "cmd": cmd}`, plus the fields in `options` (`input_format`, `format`) |
| `fetch`, `fetch(path)`, `fetch(path; options)` | `{"type": "Fetch", ...}` |
| `make_file`, `make_file(path)`, `make_file(path; options)` | `{"type": "MakeFile", ...}` |
| `jq_ref(path)` | `{"type": "Jq", "filter_ref": path}` |
| `jq_code(code)` | `{"type": "Jq", "filter_code": code}` |
| `exec`, `exec_ref(path)`, `exec_flow(flow)` | `{"type": "Exec", ...}` |

(`if`, `try` and `foreach` are jq keywords, hence the names `if_then_else`,
`try_catch` and `for_each`.)

## Running a flow

An engine runs a flow document (or a flow given in place) with an input,
`null` by default, and optionally initial named inputs. The outcome of the
flow is the outcome of the run.

## Future extensions

- **Functions and modules.** Flows declared as functions, identified within
  a module and with a defined prototype, called with
  `{"type": "FunctionCall", "ref": R, "named_input_map": {"function_input": "local_input", ...}}`:
  the function gets the input of the call and only the named inputs listed
  in the map, under their function names. The operator name `FunctionCall`
  is reserved for it.
- **Module references** in paths (e.g. to packages installed with jqpm),
  and remote resources (URLs) for Fetch and Exec.
- More formats: `bytes` (base64-encoded strings), `json_seq` (an array of
  the JSON values in the text), `lines`.
- Giving named inputs to shell commands (e.g. as environment variables).
- Filters as JSON (a JSON representation of jq programs) for Jq.

## Changes from version 0.1

Version 0.1 described *steps*: objects with a main field (`shell`, `result`,
`call`, ...) that jq filters returned to say what to do next. Version 0.2
replaces them with flows:

| 0.1 | 0.2 |
|---|---|
| `{"result": X}` | Constant |
| `{"error": E}` | Error |
| `{"shell": "cmd"}`, `"cmd"` | Shell |
| `{"fetch_file": "path"}` | Fetch |
| `{"sync_call": "f"}`, `sync_next` | Jq with `filter_ref` |
| `{"call": "f"}` (a filter returning a step) | a Jq computing a flow, then an Exec |
| `{"action": A, "next": N}` | Cascade |
| `[s1, s2, ...]` | Sequence (or Parallel) |
| `{"input": X, ...}` | a Cascade starting with a Constant |
| `args` | named inputs (Let) |
| `on_error` | Try |
| `include "async-jq";` | `import "async-jq" as aj;` |
| references relative to an application root, `foo/bar` finding `foo/bar.jq` or `foo/bar/bar.jq` | paths relative to the current file, naming files exactly |
| the engine runs a jq filter | the engine runs a flow document |

# async-jq library (see SPEC.md, "Library"), to be imported by filters:
#
#   import "async-jq" as aj;
#
# Public API: resolve_file, named_input, and the flow constructors. Names
# starting with "_" are internal (used by the engine).
#
# Note: the constructor `error(e)` shadows jq's builtin `error/1` in a filter
# that *includes* this module; importing it avoids that.

# ---------------------------------------------------------------------------
# Paths

# Removes "", "." and ".." segments from a path.
def _normalize_path:
    startswith("/") as $absolute |
    reduce (split("/")[] | select(. != "" and . != ".")) as $segment ([];
        if $segment != ".." then . + [$segment]
        elif length > 0 and .[-1] != ".." then .[:-1]
        elif $absolute then .
        else . + [".."]
        end
    ) |
    (if $absolute then "/" else "" end) + join("/");

def _dirname:
    if test("/") then sub("/[^/]*$"; "") | if . == "" then "/" else . end
    else "."
    end;

def _is_url: test("^[A-Za-z][A-Za-z0-9+.-]*://");

# Resolves the path in input against the absolute directory $base (see
# SPEC.md, "Paths"): URLs are kept as they are, absolute paths normalized,
# relative paths made absolute.
def _resolve_path($base):
    if type != "string" then error("invalid path: \(tojson)")
    elif _is_url then .
    elif startswith("/") then _normalize_path
    else "\($base)/\(.)" | _normalize_path
    end;

# ---------------------------------------------------------------------------
# Context given by the engine to the filters it runs, as
# --slurpfile __async_jq <file holding {"base": ..., "named": {...}}>

def _context:
    ($ARGS.named.__async_jq // error("no async-jq context: the filter must be run by the engine"))[0];

# absolute path of a file, relative to the filter's directory (or the base of
# the Jq flow, for a filter given as code)
def resolve_file: _resolve_path(_context.base);
def resolve_file($path): $path | resolve_file;

# value of a named input (with no size limit, unlike the $name variables)
def named_input($name):
    _context.named |
    if has($name) then .[$name] else error("no named input \($name | tojson)") end;

# ---------------------------------------------------------------------------
# Flow constructors (paths are made absolute with resolve_file)

def constant($data): {type: "Constant", data: $data};
def identity: {type: "Identity"};
def get($id): {type: "Get", input_id: $id};

def cascade($flows): {type: "Cascade", subflows: $flows};
def sequence($flows): {type: "Sequence", subflows: $flows};
def parallel($flows): {type: "Parallel", subflows: $flows};
def parallel($flows; $preserve_order): {type: "Parallel", subflows: $flows, preserve_order: $preserve_order};

def let($assign; $flow): {type: "Let", assign: $assign, subflow: $flow};

def if_then_else($condition; $then; $else): {type: "If", condition: $condition, then: $then, else: $else};
def if_then($condition; $then): {type: "If", condition: $condition, then: $then};
def switch($cases; $default): {type: "Switch", cases: $cases, default: $default};
def switch($cases): {type: "Switch", cases: $cases};
def try_catch($flow; $handler): {type: "Try", subflow: $flow, catch: $handler};
def for_each($flow): {type: "ForEach", subflow: $flow};
def for_each($flow; $parallel; $preserve_order):
    {type: "ForEach", subflow: $flow, parallel: $parallel, preserve_order: $preserve_order};
def loop($condition; $flow): {type: "Loop", while: $condition, subflow: $flow};

def shell($cmd): {type: "Shell", cmd: $cmd};
def shell($cmd; $options): {type: "Shell", cmd: $cmd} + $options;
def fetch: {type: "Fetch"};
def fetch($path): {type: "Fetch", location: ($path | resolve_file)};
def fetch($path; $options): fetch($path) + $options;
def make_file: {type: "MakeFile"};
def make_file($path): {type: "MakeFile", location: ($path | resolve_file)};
def make_file($path; $options): make_file($path) + $options;
def jq_ref($path): {type: "Jq", filter_ref: ($path | resolve_file)};
def jq_code($code): {type: "Jq", filter_code: $code};
def exec: {type: "Exec"};
def exec_ref($path): {type: "Exec", flow_ref: ($path | resolve_file)};
def exec_flow($flow): {type: "Exec", flow: $flow};

# defined last, so that the definitions above still use jq's error/1
def error($e): {type: "Error", error: $e};

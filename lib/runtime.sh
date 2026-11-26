# async-jq runtime: shell functions used by the code that lib/to-shell.jq
# generates. Loaded (with `.`) by bin/async-jq, which sets:
#
#   __aj_lib     absolute path of this directory
#   __aj_tmp     a temporary directory, removed at the end of the run
#   __aj_search  the jq search path for the filters, as shell-quoted -L
#                options (to be used with eval)
#
# Compiled flows read their input (as JSON text) from $__in and their named
# inputs from the JSON file $__scope; they print the outcome's value as JSON
# and exit with status 0 for a result, 1 for an error. The functions below
# follow the same convention; those that end a flow with an error call
# `exit 1`, so they are only called from within a flow's subshell.

# --- outcomes ---------------------------------------------------------------

__aj_engine_error() { # message
    printf '%s' "$1" | jq -Rsc '{type: "engine", message: .}'
}

# fails with the error value $1 (an engine error if it is empty, i.e. if the
# flow that should have produced it crashed)
__aj_fail() {
    if [ -n "$1" ]; then
        printf '%s\n' "$1"
    else
        __aj_engine_error "a flow ended without an outcome"
    fi
    exit 1
}

__aj_error_value() {
    if [ -n "$1" ]; then printf '%s\n' "$1"; else __aj_engine_error "a flow ended without an outcome"; fi
}

__aj_tmpfile() {
    mktemp "$__aj_tmp/f.XXXXXX" 2>/dev/null || __aj_fail "$(__aj_engine_error "cannot create a temporary file")"
}

# --- paths ------------------------------------------------------------------

__aj_resolve() { # base path
    jq -nr -L "$__aj_lib" --arg base "$1" --arg path "$2" \
        'import "async-jq" as aj; $path | aj::_resolve_path($base)'
}

__aj_is_url() {
    case "$1" in
        [A-Za-z]*://*) return 0 ;;
        *) return 1 ;;
    esac
}

# --- named inputs -------------------------------------------------------------

# prints the path of a new scope file: the current one with the given
# bindings added (name value ...)
__aj_bind() {
    __obj=
    while [ $# -ge 2 ]; do
        __obj="$__obj${__obj:+,}\"$1\":$2"
        shift 2
    done
    __f=$(__aj_tmpfile) || exit 1
    printf '{%s}\n' "$__obj" | jq -c -s '.[0] + .[1]' "$__scope" - > "$__f" ||
        __aj_fail "$(__aj_engine_error "cannot bind named inputs")"
    printf '%s\n' "$__f"
}

# prints the path of a scope file without the named input $1
__aj_unbind() {
    if jq -e --arg name "$1" 'has($name)' "$__scope" >/dev/null; then
        __f=$(__aj_tmpfile) || exit 1
        jq -c --arg name "$1" 'del(.[$name])' "$__scope" > "$__f" ||
            __aj_fail "$(__aj_engine_error "cannot unbind a named input")"
        printf '%s\n' "$__f"
    else
        printf '%s\n' "$__scope"
    fi
}

__aj_get() { # name
    if jq -e --arg name "$1" 'has($name)' "$__scope" >/dev/null; then
        jq -c --arg name "$1" '.[$name]' "$__scope"
    else
        jq -nc --arg name "$1" '{type: "input", input_id: $name, message: "no named input \($name)"}'
        exit 1
    fi
}

# --- data formats -------------------------------------------------------------

# prints $__in as text according to the input format $1; on a type error,
# prints the error and returns 1
__aj_serialize() {
    if [ "$1" = json ]; then
        printf '%s\n' "$__in" | jq -c .
        return
    fi
    __t=$(printf '%s\n' "$__in" | jq -r type) || return 1
    if [ "$__t" = string ]; then
        printf '%s\n' "$__in" | jq -j .
    elif [ "$1" = text ]; then
        jq -nc --arg t "$__t" '{type: "type", message: "input_format text requires a string, got \($t)"}'
        return 1
    else
        printf '%s\n' "$__in" | jq -c .
    fi
}

# parses the text on stdin according to the output format $1, printing the
# value; on a parse error, prints the error and returns 1
__aj_parse() {
    case "$1" in
        text) jq -Rsc . ;;
        json)
            __r=$(jq -Rsc 'try {r: fromjson} catch {e: {type: "parse", format: "json", message: .}}') || return 1
            case "$__r" in
                '{"r":'*) __r=${__r#'{"r":'}; printf '%s\n' "${__r%\}}" ;;
                *) __r=${__r#'{"e":'}; printf '%s\n' "${__r%\}}"; return 1 ;;
            esac
            ;;
        *) jq -Rsc '. as $s | if $s == "" then "" else (try fromjson catch $s) end' ;;
    esac
}

# --- Shell, Fetch, MakeFile ---------------------------------------------------

__aj_shell() { # cmd input_format format
    __cmd=$1
    if [ "$__in" = null ]; then
        __out=$(set --; eval "$__cmd" </dev/null)
        __st=$?
    else
        __f=$(__aj_tmpfile) || exit 1
        __aj_serialize "$2" > "$__f" || __aj_fail "$(cat "$__f")"
        __out=$(set --; eval "$__cmd" < "$__f")
        __st=$?
    fi
    if [ "$__st" -ne 0 ]; then
        printf '%s' "$__cmd" | jq -Rsc --argjson status "$__st" '{type: "shell", cmd: ., status: $status}'
        exit 1
    fi
    printf '%s' "$__out" | __aj_parse "$3" || exit 1
}

__aj_fetch_error() { # location message
    jq -nc --arg location "$1" --arg message "$2" '{type: "fetch", location: $location, message: $message}'
    exit 1
}

__aj_fetch() { # path format
    __aj_is_url "$1" && __aj_fetch_error "$1" "remote resources are not supported yet"
    [ -f "$1" ] || __aj_fetch_error "$1" "file not found"
    [ -r "$1" ] || __aj_fetch_error "$1" "file not readable"
    __aj_parse "$2" < "$1" || exit 1
}

# the location as a string input
__aj_string_input() { # what
    __t=$(printf '%s\n' "$__in" | jq -r type) || exit 1
    if [ "$__t" != string ]; then
        jq -nc --arg what "$1" --arg t "$__t" '{type: "type", message: "\($what) must be a string, got \($t)"}'
        exit 1
    fi
    printf '%s\n' "$__in" | jq -r .
}

__aj_fetch_input() { # base format
    __p=$(__aj_string_input "the input of Fetch") || __aj_fail "$__p"
    __aj_is_url "$__p" || __p=$(__aj_resolve "$1" "$__p")
    __aj_fetch "$__p" "$2"
}

__aj_make_file() { # path input_format
    if __aj_is_url "$1"; then
        jq -nc --arg location "$1" '{type: "make_file", location: $location, message: "remote resources are not supported"}'
        exit 1
    fi
    __f=$(__aj_tmpfile) || exit 1
    __aj_serialize "$2" > "$__f" || __aj_fail "$(cat "$__f")"
    if ! cat "$__f" 2>/dev/null > "$1"; then
        jq -nc --arg location "$1" '{type: "make_file", location: $location, message: "cannot write the file"}'
        exit 1
    fi
    printf '%s' "$1" | jq -Rc .
}

# MakeFile without a location field: the named input `location`, if any,
# otherwise a temporary file
__aj_make_file_named() { # base input_format
    if jq -e 'has("location")' "$__scope" >/dev/null; then
        __p=$(jq -r 'if (.location | type) == "string" then .location else empty end' "$__scope")
        if [ -z "$__p" ]; then
            jq -nc '{type: "type", message: "the named input location must be a non-empty string"}'
            exit 1
        fi
        __aj_is_url "$__p" || __p=$(__aj_resolve "$1" "$__p")
        __aj_make_file "$__p" "$2"
    else
        __p=$(mktemp "$__aj_tmp/file.XXXXXX") || __aj_fail "$(__aj_engine_error "cannot create a temporary file")"
        __aj_make_file "$__p" "$2"
    fi
}

# --- Jq ------------------------------------------------------------------------

# Named inputs whose JSON text is at most this long are bound as $name
# variables (as long as their total stays within __AJ_VARS_TOTAL), since
# command-line arguments are limited in size; all of them are available
# through named_input(name).
__AJ_VAR_MAX=100000
__AJ_VARS_TOTAL=1000000

# fails with a jq error; the message is $3 if given, otherwise read from
# stdin (redirected from a file: in a pipeline, the function would run in a
# subshell, and its exit wouldn't end the flow)
__aj_jq_error() { # filter status [message]
    if [ $# -ge 3 ]; then
        printf '%s' "$3" | jq -Rsc --arg filter "$1" --argjson status "$2" '{type: "jq", filter: $filter, status: $status, message: .}'
    else
        jq -Rsc --arg filter "$1" --argjson status "$2" '{type: "jq", filter: $filter, status: $status, message: .}'
    fi
    exit 1
}

__aj_jq() { # filter_file filter_code base
    if [ -n "$1" ]; then
        __file=$1
        __name=$1
        [ -f "$__file" ] || __aj_jq_error "$__name" 2 "filter not found: $__file"
    else
        __file=$(__aj_tmpfile) || exit 1
        printf '%s\n' "$2" > "$__file"
        __name="(filter_code)"
    fi
    __ctx=$(__aj_tmpfile) || exit 1
    jq -c --arg base "$3" '{base: $base, named: .}' "$__scope" > "$__ctx" ||
        __aj_fail "$(__aj_engine_error "cannot write the filter context")"
    eval "set -- $__aj_search $(jq -r --argjson max "$__AJ_VAR_MAX" --argjson total "$__AJ_VARS_TOTAL" '
        reduce (to_entries[] | {key, json: (.value | tojson)}) as $e ({size: 0, args: []};
            if ($e.json | length) <= $max and .size + ($e.json | length) <= $total
            then {size: (.size + ($e.json | length)), args: (.args + ["--argjson", $e.key, $e.json])}
            else . end) |
        .args | map(@sh) | join(" ")' "$__scope")"
    __errf=$(__aj_tmpfile) || exit 1
    __out=$(printf '%s\n' "$__in" | jq -c "$@" --slurpfile __async_jq "$__ctx" -f "$__file" 2>"$__errf")
    __st=$?
    if [ "$__st" -ne 0 ]; then
        __aj_jq_error "$__name" "$__st" < "$__errf"
    fi
    if [ -s "$__errf" ]; then cat "$__errf" >&2; fi
    __n=$(printf '%s\n' "$__out" | jq -s length)
    if [ "$__n" != 1 ]; then
        __aj_jq_error "$__name" 0 "the filter must output exactly one value, got $__n"
    fi
    printf '%s\n' "$__out"
}

# --- Exec ----------------------------------------------------------------------

# compiles the flow on stdin, with base $1, printing the shell code
__aj_compile() {
    jq -r -L "$__aj_lib" -f "$__aj_lib/to-shell.jq" --arg base "$1"
}

# evaluates the flow $1 (JSON text) with base $2, without the named input flow
__aj_exec_value() {
    __scope=$(__aj_unbind flow) || __aj_fail "$__scope"
    __script=$(printf '%s\n' "$1" | __aj_compile "$2") ||
        __aj_fail "$(__aj_engine_error "cannot compile the flow")"
    eval "$__script"
}

__aj_exec_file() { # path
    __aj_is_url "$1" && __aj_fetch_error "$1" "remote resources are not supported yet"
    [ -f "$1" ] || __aj_fetch_error "$1" "flow document not found"
    __flow=$(__aj_parse json < "$1") || __aj_fail "$__flow"
    __aj_exec_value "$__flow" "$(dirname "$1")"
}

__aj_exec_named() { # base
    __flow=$(__aj_get flow) || __aj_fail "$__flow"
    __aj_exec_value "$__flow" "$1"
}

# --- Parallel, ForEach, Loop ------------------------------------------------------

# prints the array of the values in $1/1.value ... $1/$2.value, in subflow
# order if $3 is true, otherwise in completion order; fails with the first
# error in subflow order
__aj_collect() { # dir count preserve_order
    __i=1
    while [ "$__i" -le "$2" ]; do
        if [ "$(cat "$1/$__i.status" 2>/dev/null)" != 0 ]; then
            __aj_fail "$(cat "$1/$__i.value" 2>/dev/null)"
        fi
        __i=$((__i + 1))
    done
    if [ "$3" = true ]; then
        __order=
        __i=1
        while [ "$__i" -le "$2" ]; do __order="$__order $__i"; __i=$((__i + 1)); done
    else
        __order=$(cat "$1/order")
    fi
    __sep=
    printf '['
    for __i in $__order; do
        printf '%s' "$__sep"
        cat "$1/$__i.value"
        __sep=,
    done
    printf ']\n'
}

# runs the function $3 in the background, with input $2, as job number $4,
# storing its outcome in the directory $1
__aj_job() { # dir input function number
    (
        __in=$2
        __v=$("$3")
        printf '%s\n' "$?" > "$1/$4.status"
        printf '%s' "$__v" > "$1/$4.value"
        printf '%s\n' "$4" >> "$1/order"
    ) &
}

__aj_parallel() { # preserve_order function...
    __preserve=$1
    shift
    __d=$(mktemp -d "$__aj_tmp/p.XXXXXX") || __aj_fail "$(__aj_engine_error "cannot create a temporary directory")"
    : > "$__d/order"
    __n=0
    for __fn in "$@"; do
        __n=$((__n + 1))
        __aj_job "$__d" "$__in" "$__fn" "$__n"
    done
    wait
    __aj_collect "$__d" "$__n" "$__preserve"
}

__aj_for_each() { # parallel preserve_order function
    __t=$(printf '%s\n' "$__in" | jq -r type) || exit 1
    if [ "$__t" != array ]; then
        jq -nc --arg t "$__t" '{type: "type", message: "the input of ForEach must be an array, got \($t)"}'
        exit 1
    fi
    __d=$(mktemp -d "$__aj_tmp/e.XXXXXX") || __aj_fail "$(__aj_engine_error "cannot create a temporary directory")"
    printf '%s\n' "$__in" | jq -c '.[]' > "$__d/elements"
    : > "$__d/order"
    __n=0
    if [ "$1" = true ]; then
        while IFS= read -r __el <&3; do
            __n=$((__n + 1))
            __aj_job "$__d" "$__el" "$3" "$__n"
        done 3< "$__d/elements"
        wait
        __aj_collect "$__d" "$__n" "$2"
    else
        __sep=
        printf '[' > "$__d/result"
        while IFS= read -r __el <&3; do
            __v=$(__in=$__el; "$3") || __aj_fail "$__v"
            printf '%s%s' "$__sep" "$__v" >> "$__d/result"
            __sep=,
        done 3< "$__d/elements"
        printf ']\n' >> "$__d/result"
        cat "$__d/result"
    fi
}

__aj_loop() { # condition_function body_function
    while :; do
        __c=$("$1") || __aj_fail "$__c"
        case "$__c" in
            false|null) break ;;
        esac
        __v=$("$2") || __aj_fail "$__v"
        __in=$__v
    done
    printf '%s\n' "$__in"
}

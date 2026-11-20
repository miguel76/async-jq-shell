#!/bin/sh
# Runs the test cases in cases.json.
#
# Usage: tests/run.sh [pattern]
#   pattern   only run the cases whose name contains it
#
# Environment:
#   ASYNC_JQ  the command to test (default: ../bin/async-jq)
#
# Each case runs `async-jq --envelope [options] <filter>` in this directory,
# with FLOW_PATH=flow and DATA_PATH=., and checks the final envelope. In the
# envelope, the absolute path of this directory is replaced by "<tests>".
#
# Case fields:
#   name          unique name
#   filter        the filter to run
#   options       (optional) array of extra options for async-jq
#   env           (optional) object of environment variables to set
#   stdin         (optional) JSON value given (as text) on stdin
#   stdin_jq      (optional) jq expression whose value is given on stdin
#   expect        (optional) the expected envelope, exactly
#   expect_error  (optional) the envelope must be an error that `contains` it
#                 (as jq's `contains`: strings match as substrings)
#   expect_jq     (optional) jq expression that must be true on the envelope
#   expect_exit   (optional) expected exit status (default: 0 for a result,
#                 1 for an error)
#   stderr_contains (optional) string that stderr must contain

cd "$(dirname "$0")" || exit 1
TESTS=$(pwd)
ASYNC_JQ=${ASYNC_JQ:-$TESTS/../bin/async-jq}
FLOW_PATH=flow
DATA_PATH=.
export FLOW_PATH DATA_PATH

PATTERN=$1
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

COUNT=$(jq length cases.json) || exit 1
PASSED=0
FAILED=0
FAILURES=
i=0
while [ "$i" -lt "$COUNT" ]; do
    TC=$(jq -c ".[$i]" cases.json)
    i=$((i + 1))
    NAME=$(printf '%s' "$TC" | jq -r '.name')
    if [ -n "$PATTERN" ]; then
        case "$NAME" in
            *"$PATTERN"*) ;;
            *) continue ;;
        esac
    fi

    # stdin
    if printf '%s' "$TC" | jq -e 'has("stdin")' >/dev/null; then
        printf '%s' "$TC" | jq -c '.stdin' > "$TMP/stdin"
    elif printf '%s' "$TC" | jq -e 'has("stdin_jq")' >/dev/null; then
        jq -nc "$(printf '%s' "$TC" | jq -r '.stdin_jq')" > "$TMP/stdin"
    else
        : > "$TMP/stdin"
    fi

    # run, through env to set the case's environment variables:
    #   env [VAR=VALUE]... $ASYNC_JQ --envelope [OPTION]... FILTER
    eval "set -- $(printf '%s' "$TC" | jq -r --arg async_jq "$ASYNC_JQ" '
        [((.env // {}) | to_entries[] | "\(.key)=\(.value)"),
         $async_jq, "--envelope", (.options // [])[], .filter] | map(@sh) | join(" ")')"
    env "$@" < "$TMP/stdin" > "$TMP/stdout" 2> "$TMP/stderr"
    STATUS=$?
    jq -c --arg tests "$TESTS" 'walk(if type == "string" then split($tests) | join("<tests>") else . end)' \
        "$TMP/stdout" > "$TMP/actual" 2>/dev/null || : > "$TMP/actual"

    # checks
    PROBLEMS=$(jq -nr --slurpfile actual "$TMP/actual" --argjson tc "$TC" --argjson status "$STATUS" '
        ($actual[0]) as $env |
        (if $tc | has("expect_exit") then $tc.expect_exit
         elif ($tc.expect // {}) | has("error") then 1
         elif $tc | has("expect_error") then 1
         else 0 end) as $exit |
        (if $tc | has("expect") and $env != $tc.expect then
            "expected \($tc.expect | tojson), got \($env | tojson)" else empty end),
        (if $tc | has("expect_error") and (($env | type) != "object" or ($env | has("error") | not) or ($env.error | contains($tc.expect_error) | not)) then
            "expected an error containing \($tc.expect_error | tojson), got \($env | tojson)" else empty end),
        (if $status != $exit then "expected exit status \($exit), got \($status)" else empty end)
    ')
    if printf '%s' "$TC" | jq -e 'has("expect_jq")' >/dev/null; then
        EXPR=$(printf '%s' "$TC" | jq -r '.expect_jq')
        if ! jq -e "$EXPR" "$TMP/actual" >/dev/null 2>&1; then
            PROBLEMS="${PROBLEMS:+$PROBLEMS
}expected $EXPR to be true, got $(head -c 300 "$TMP/actual")"
        fi
    fi
    if printf '%s' "$TC" | jq -e 'has("stderr_contains")' >/dev/null; then
        EXPECTED_STDERR=$(printf '%s' "$TC" | jq -r '.stderr_contains')
        if ! grep -qF -- "$EXPECTED_STDERR" "$TMP/stderr"; then
            PROBLEMS="${PROBLEMS:+$PROBLEMS
}expected stderr to contain $EXPECTED_STDERR, got: $(head -c 300 "$TMP/stderr")"
        fi
    fi

    if [ -z "$PROBLEMS" ]; then
        PASSED=$((PASSED + 1))
        echo "ok   $NAME"
    else
        FAILED=$((FAILED + 1))
        FAILURES="$FAILURES $NAME"
        echo "FAIL $NAME"
        printf '%s\n' "$PROBLEMS" | cut -c1-400 | sed 's/^/     /'
    fi
done

echo
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] || { echo "failed:$FAILURES"; exit 1; }

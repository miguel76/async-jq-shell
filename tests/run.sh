#!/bin/sh
# Runs the test cases in cases.json.
#
# Usage: tests/run.sh [pattern]
#   pattern   only run the cases whose name contains it
#
# Environment:
#   ASYNC_JQ  the command to test (default: ../bin/async-jq)
#
# Each case runs `async-jq --envelope [options] (--flow FLOW | FLOW_FILE)` in
# a copy of this directory and checks the final envelope. In the envelope, the absolute
# path of this directory is replaced by "<tests>". The directory out/ is
# emptied before the cases run, for the files they write.
#
# Case fields:
#   name          unique name
#   flow          the flow to run, given in place (relative paths are
#                 relative to this directory)
#   flow_file     or the flow document to run
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
#   max_seconds   (optional) the run must take at most this many seconds
#                 (whole seconds, as measured by date +%s)

cd "$(dirname "$0")" || exit 1
ASYNC_JQ=${ASYNC_JQ:-$(pwd)/../bin/async-jq}
rm -rf out && mkdir out || exit 1

PATTERN=$1
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

# the cases run in a copy of this directory, so that nothing outside it (like
# the engine's ../lib, which jq would find from here) can affect them
mkdir "$TMP/tests" && cp -R . "$TMP/tests" || exit 1
cd "$TMP/tests" || exit 1
TESTS=$(pwd)

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
    #   env [VAR=VALUE]... $ASYNC_JQ --envelope [OPTION]... (--flow FLOW | FLOW_FILE)
    eval "set -- $(printf '%s' "$TC" | jq -r --arg async_jq "$ASYNC_JQ" '
        [((.env // {}) | to_entries[] | "\(.key)=\(.value)"),
         $async_jq, "--envelope", (.options // [])[],
         (if has("flow") then "--flow", (.flow | tojson) else .flow_file end)] | map(@sh) | join(" ")')"
    START=$(date +%s)
    env "$@" < "$TMP/stdin" > "$TMP/stdout" 2> "$TMP/stderr"
    STATUS=$?
    ELAPSED=$(($(date +%s) - START))
    jq -c --arg tests "$TESTS" 'walk(if type == "string" then split($tests) | join("<tests>") else . end)' \
        "$TMP/stdout" > "$TMP/actual" 2>/dev/null || : > "$TMP/actual"

    # checks
    PROBLEMS=$(jq -nr --slurpfile actual "$TMP/actual" --argjson tc "$TC" --argjson status "$STATUS" \
        --argjson elapsed "$ELAPSED" '
        ($actual[0]) as $env |
        (if $tc | has("expect_exit") then $tc.expect_exit
         elif ($tc.expect // {}) | has("error") then 1
         elif $tc | has("expect_error") then 1
         else 0 end) as $exit |
        (if $tc | has("expect") and $env != $tc.expect then
            "expected \($tc.expect | tojson), got \($env | tojson)" else empty end),
        (if $tc | has("expect_error") and (($env | type) != "object" or ($env | has("error") | not) or ($env.error | contains($tc.expect_error) | not)) then
            "expected an error containing \($tc.expect_error | tojson), got \($env | tojson)" else empty end),
        (if $status != $exit then "expected exit status \($exit), got \($status)" else empty end),
        (if $tc | has("max_seconds") and $elapsed > $tc.max_seconds then
            "expected to take at most \($tc.max_seconds)s, took \($elapsed)s" else empty end)
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

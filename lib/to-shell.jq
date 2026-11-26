# Compiles a flow (see SPEC.md) into POSIX shell code.
#
# Input: the flow (a JSON value). Arguments:
#   --arg base   absolute directory against which the flow's relative paths
#                are resolved
#
# The generated code is a compound command, to be run (with eval) in a shell
# where lib/runtime.sh is loaded. It reads the flow's input from the shell
# variable $__in (as JSON text) and its named inputs from the JSON file whose
# path is in $__scope, prints the outcome's value as JSON on stdout, and
# exits with status 0 for a result, 1 for an error.
#
# The whole flow is checked first: an invalid flow compiles to code failing
# with a "flow" error.

import "async-jq" as aj;

def q: tostring | @sh;

# ---------------------------------------------------------------------------
# Validation

def operators: {
    Constant: {required: ["data"], optional: []},
    Identity: {required: [], optional: []},
    Get: {required: ["input_id"], optional: []},
    Error: {required: ["error"], optional: []},
    Cascade: {required: ["subflows"], optional: []},
    Sequence: {required: ["subflows"], optional: []},
    Parallel: {required: ["subflows"], optional: ["preserve_order"]},
    Let: {required: ["assign", "subflow"], optional: []},
    If: {required: ["condition", "then"], optional: ["else"]},
    Switch: {required: ["cases"], optional: ["default"]},
    Try: {required: ["subflow", "catch"], optional: []},
    ForEach: {required: ["subflow"], optional: ["parallel", "preserve_order"]},
    Loop: {required: ["while", "subflow"], optional: []},
    Shell: {required: ["cmd"], optional: ["input_format", "format"]},
    Fetch: {required: [], optional: ["location", "format"]},
    MakeFile: {required: [], optional: ["location", "input_format"]},
    Jq: {required: [], optional: ["filter_ref", "filter_code"]},
    Exec: {required: [], optional: ["flow_ref", "flow"]}
};

def name_ok: type == "string" and test("^[A-Za-z_][A-Za-z0-9_]*$")
    and (. == "ENV" or . == "ARGS" or startswith("__") | not);

# raises an error object {message, flow} for the first problem found
def check:
    def fail($message; $flow): error({message: $message, flow: $flow});
    def check_flows($what):
        if type != "array" then fail("\($what) must be an array of flows"; .)
        else .[] | check end;
    if type != "object" then fail("a flow must be an object"; .)
    elif (.type | type) != "string" then fail("a flow must have a type"; .)
    elif .type == "FunctionCall" then fail("FunctionCall is not supported yet"; .)
    else . end |
    . as $flow |
    (operators[.type] // fail("unknown operator \(.type | tojson)"; $flow)) as $spec |
    ([keys[] | select(. != "type" and (. as $k | $spec.required + $spec.optional | index($k) | not))]) as $unknown |
    ([$spec.required[] | select(. as $k | $flow | has($k) | not)]) as $missing |
    if ($unknown | length) > 0 then fail("unknown field(s) \($unknown | join(", ")) for \(.type)"; $flow)
    elif ($missing | length) > 0 then fail("missing field(s) \($missing | join(", ")) for \(.type)"; $flow)
    else
        if .type == "Get" then
            if (.input_id | name_ok) then empty else fail("input_id must be a valid named input name"; $flow) end
        elif .type == "Cascade" or .type == "Sequence" or .type == "Parallel" then
            (.subflows | check_flows("subflows")),
            (if has("preserve_order") and (.preserve_order | type) != "boolean" then fail("preserve_order must be a boolean"; $flow) else empty end)
        elif .type == "Let" then
            if (.assign | type) != "object" then fail("assign must be an object"; $flow)
            elif (.assign | keys | all(name_ok) | not) then fail("assign names must be valid named input names"; $flow)
            else (.assign[] | check), (.subflow | check) end
        elif .type == "If" then (.condition, .then, (.else // empty)) | check
        elif .type == "Switch" then
            if (.cases | type) != "array" or (.cases | all(type == "object" and (keys == ["do", "when"])) | not) then
                fail("cases must be an array of {when, do} objects"; $flow)
            else (.cases[] | .when, .do), (.default // empty) | check end
        elif .type == "Try" then (.subflow, .catch) | check
        elif .type == "ForEach" then
            (.subflow | check),
            (if (.parallel // false | type) != "boolean" or (.preserve_order // false | type) != "boolean" then
                fail("parallel and preserve_order must be booleans"; $flow) else empty end)
        elif .type == "Loop" then (.while, .subflow) | check
        elif .type == "Shell" then
            if (.cmd | type) != "string" then fail("cmd must be a string"; $flow) else empty end
        elif .type == "Jq" then
            if (has("filter_ref") and has("filter_code")) or (has("filter_ref") or has("filter_code") | not) then
                fail("Jq must have either filter_ref or filter_code"; $flow)
            elif ((.filter_ref // .filter_code) | type) != "string" then fail("filter_ref and filter_code must be strings"; $flow)
            else empty end
        elif .type == "Exec" then
            if has("flow_ref") and has("flow") then fail("Exec can't have both flow_ref and flow"; $flow)
            elif has("flow_ref") and (.flow_ref | type) != "string" then fail("flow_ref must be a string"; $flow)
            elif has("flow") then .flow | check
            else empty end
        else empty end,
        (if has("location") and (.location | type) != "string" then fail("location must be a string"; $flow) else empty end),
        (if has("format") and (.format | IN("auto", "json", "text") | not) then
            fail("format must be one of auto, json, text"; $flow) else empty end),
        (if has("input_format") and (.input_format | IN("auto", "json", "text") | not) then
            fail("input_format must be one of auto, json, text"; $flow) else empty end)
    end;

# ---------------------------------------------------------------------------
# Compilation

def path_of: aj::_resolve_path($base);

# A subflow is compiled to a compound command `( ... )`; where the runtime
# needs to run it (Parallel, ForEach, Loop), it is wrapped in a shell function
# named after the node's position ($id), unique within the compiled flow.
def fname($id): "__aj_sub\($id)";

def compile($id):
    def sub($i): "\($id)_\($i)";
    if .type == "Constant" then
        "( printf '%s\\n' \(.data | tojson | q) )"
    elif .type == "Identity" then
        "( printf '%s\\n' \"$__in\" )"
    elif .type == "Get" then
        "( __aj_get \(.input_id | q) )"
    elif .type == "Error" then
        "( printf '%s\\n' \(.error | tojson | q); exit 1 )"
    elif .type == "Cascade" then
        "( " + ([.subflows | to_entries[] |
            "__v=$( \(.value | compile(sub(.key))) ) || __aj_fail \"$__v\"; __in=$__v; "] | add // "") +
        "printf '%s\\n' \"$__in\" )"
    elif .type == "Sequence" then
        "( " + ([.subflows | to_entries[] |
            "__v\(.key)=$( \(.value | compile(sub(.key))) ) || __aj_fail \"$__v\(.key)\"; "] | add // "") +
        "printf '[%s]\\n' \"" + ([.subflows | keys[] | "$__v\(.)"] | join(",")) + "\" )"
    elif .type == "Parallel" then
        "( " + ([.subflows | to_entries[] | "\(fname(sub(.key)))() \(.value | compile(sub(.key)))\n"] | add // "") +
        "__aj_parallel \(.preserve_order // false) " + ([.subflows | keys[] | fname(sub(.))] | join(" ")) + " )"
    elif .type == "Let" then
        (.assign | to_entries | sort_by(.key)) as $assign |
        "( " + ([$assign | to_entries[] |
            "__a\(.key)=$( \(.value.value | compile(sub("a\(.key)"))) ) || __aj_fail \"$__a\(.key)\"; "] | add // "") +
        "__scope=$(__aj_bind" + ([$assign | to_entries[] | " \(.value.key | q) \"$__a\(.key)\""] | add // "") +
        ") || __aj_fail \"$__scope\"; " +
        (.subflow | compile(sub("s"))) + " )"
    elif .type == "If" then
        "( __c=$( \(.condition | compile(sub("c"))) ) || __aj_fail \"$__c\"; case \"$__c\" in false|null) " +
        ((.else // {type: "Identity"}) | compile(sub("e"))) + " ;; *) " +
        (.then | compile(sub("t"))) + " ;; esac )"
    elif .type == "Switch" then
        reduce (.cases | to_entries | reverse[]) as $case
            ((.default // {type: "Identity"}) | compile(sub("d"));
             "( __c=$( \($case.value.when | compile(sub("w\($case.key)"))) ) || __aj_fail \"$__c\"; " +
             "case \"$__c\" in false|null) \(.) ;; *) \($case.value.do | compile(sub("d\($case.key)"))) ;; esac )")
    elif .type == "Try" then
        "( if __v=$( \(.subflow | compile(sub("s"))) ); then printf '%s\\n' \"$__v\"; " +
        "else __in=$(__aj_error_value \"$__v\"); \(.catch | compile(sub("c"))); fi )"
    elif .type == "ForEach" then
        "( \(fname(sub("s")))() \(.subflow | compile(sub("s")))\n" +
        "__aj_for_each \(.parallel // false) \(.preserve_order // false) \(fname(sub("s"))) )"
    elif .type == "Loop" then
        "( \(fname(sub("w")))() \(.while | compile(sub("w")))\n" +
        "\(fname(sub("s")))() \(.subflow | compile(sub("s")))\n" +
        "__aj_loop \(fname(sub("w"))) \(fname(sub("s"))) )"
    elif .type == "Shell" then
        "( __aj_shell \(.cmd | q) \(.input_format // "auto") \(.format // "auto") )"
    elif .type == "Fetch" then
        if has("location") then "( __aj_fetch \(.location | path_of | q) \(.format // "auto") )"
        else "( __aj_fetch_input \($base | q) \(.format // "auto") )" end
    elif .type == "MakeFile" then
        if has("location") then "( __aj_make_file \(.location | path_of | q) \(.input_format // "auto") )"
        else "( __aj_make_file_named \($base | q) \(.input_format // "auto") )" end
    elif .type == "Jq" then
        if has("filter_ref") then
            (.filter_ref | path_of) as $file |
            "( __aj_jq \($file | q) '' \($file | aj::_dirname | q) )"
        else
            "( __aj_jq '' \(.filter_code | q) \($base | q) )"
        end
    elif .type == "Exec" then
        if has("flow_ref") then "( __aj_exec_file \(.flow_ref | path_of | q) )"
        elif has("flow") then
            "( __scope=$(__aj_unbind flow) || __aj_fail \"$__scope\"; \(.flow | compile(sub("f"))) )"
        else "( __aj_exec_named \($base | q) )" end
    else
        error("unexpected operator \(.type)")
    end;

. as $flow |
try ($flow | [check] | $flow | compile("0"))
catch (
    (if type == "object" and has("message") then . else {message: tostring, flow: $flow} end) as $e |
    "( printf '%s\\n' \({type: "flow", message: $e.message, flow: $e.flow} | tojson | q); exit 1 )"
)

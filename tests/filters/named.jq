import "async-jq" as aj;
{var: $x, args: ($ARGS.named | del(.__async_jq)), lib: aj::named_input("x")}

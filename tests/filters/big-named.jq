import "async-jq" as aj;
{length: (aj::named_input("big") | length), bound: ($ARGS.named | has("big"))}

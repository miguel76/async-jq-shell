import "async-jq" as aj;
[aj::resolve_file("./x.csv"), ("../data/y" | aj::resolve_file), aj::resolve_file("/etc/../tmp/q")]

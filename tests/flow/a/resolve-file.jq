include "async-jq"; {result: [resolve_file("./x.csv"), ("data/y" | resolve_file), resolve_filter("./z"), resolve_file("/etc/../tmp/q"), resolve_file("../../w")]}

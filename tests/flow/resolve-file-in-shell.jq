include "async-jq"; {action: "cat \(resolve_file("data/d.json") | @sh)", next: "show"}

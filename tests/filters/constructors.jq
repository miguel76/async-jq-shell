import "async-jq" as aj;
[aj::constant(1), aj::identity, aj::get("x"), aj::error("e"), aj::sequence([]), aj::parallel([]; true),
 aj::let({x: aj::constant(1)}; aj::get("x")), aj::if_then_else(aj::identity; aj::constant(1); aj::constant(2)),
 aj::if_then(aj::identity; aj::constant(1)), aj::switch([{when: aj::identity, do: aj::identity}]),
 aj::try_catch(aj::identity; aj::identity), aj::for_each(aj::identity), aj::for_each(aj::identity; true; false),
 aj::loop(aj::identity; aj::identity), aj::shell("ls"), aj::shell("ls"; {format: "text"}), aj::fetch,
 aj::fetch("x.json"), aj::make_file, aj::make_file("out.txt"), aj::jq_ref("f.jq"), aj::jq_code("."),
 aj::exec, aj::exec_ref("f.json"), aj::exec_flow(aj::identity)]

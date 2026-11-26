# builds a flow with the library's constructors; its paths are made absolute
import "async-jq" as aj;
aj::cascade([aj::fetch("../data/d.json"), aj::jq_ref("./get-x.jq"), aj::jq_code(". * 10")])

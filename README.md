# async-jq-shell
This is an experiment in running asynchronous jq filters: a filter, instead of returning its output directly, can return a description of the actions to run next (e.g. shell commands) and of the filter that will process their output.

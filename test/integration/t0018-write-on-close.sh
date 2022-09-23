#!/bin/sh
. ./test-lib.sh
t_plan 4 "write-on-close tests for funky response-bodies"

t_begin "setup and start" && {
	pitchfork_setup
	pitchfork_spawn -c $pitchfork_config write-on-close.ru
	pitchfork_wait_start
}

t_begin "write-on-close response body succeeds" && {
	test xGoodbye = x"$(curl -sSf http://$listen/)"
}

t_begin "killing succeeds" && {
	kill $pitchfork_pid
}

t_begin "check stderr" && {
	check_stderr
}

t_done

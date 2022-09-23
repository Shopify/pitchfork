#!/bin/sh
. ./test-lib.sh
t_plan 3 "test the -N / --no-default-middleware option"

t_begin "setup and start" && {
	pitchfork_setup
	pitchfork_spawn -N -c $pitchfork_config fails-rack-lint.ru
	pitchfork_wait_start
}

t_begin "check exit status with Rack::Lint not present" && {
	test 42 -eq "$(curl -sf -o/dev/null -w'%{http_code}' http://$listen/)"
}

t_begin "killing succeeds" && {
	kill $pitchfork_pid
	check_stderr
}

t_done

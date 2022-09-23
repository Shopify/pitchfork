#!/bin/sh
. ./test-lib.sh
t_plan 4 "rewindable_input toggled to true"

t_begin "setup and start" && {
	pitchfork_setup
	echo rewindable_input true >> $pitchfork_config
	pitchfork_spawn -c $pitchfork_config t0014.ru
	pitchfork_wait_start
}

t_begin "ensure worker is started" && {
	test xOK = x$(curl -T t0014.ru -sSf http://$listen/)
}

t_begin "killing succeeds" && {
	kill $pitchfork_pid
}

t_begin "check stderr" && {
	check_stderr
}

t_done

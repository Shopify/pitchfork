#!/bin/sh
. ./test-lib.sh
t_plan 4 "rewindable_input toggled to false"

t_begin "setup and start" && {
	pitchfork_setup
	echo rewindable_input false >> $pitchfork_config
	pitchfork_spawn -c $pitchfork_config t0013.ru
	pitchfork_wait_start
}

t_begin "ensure worker is started" && {
	test xOK = x$(curl -T t0013.ru -H Expect: -vsSf http://$listen/)
}

t_begin "killing succeeds" && {
	kill $pitchfork_pid
}

t_begin "check stderr" && {
	check_stderr
}

t_done

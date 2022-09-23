#!/bin/sh
. ./test-lib.sh

# Raindrops::Middleware depends on Pitchfork.listener_names,
# ensure we don't break Raindrops::Middleware.

t_plan 4 "Pitchfork.listener_names available"

t_begin "setup and startup" && {
	pitchfork_setup
	pitchfork_spawn -E none listener_names.ru -c $pitchfork_config
	pitchfork_wait_start
}

t_begin "read listener names includes listener" && {
	resp=$(curl -sSf http://$listen/)
	ok=false
	t_info "resp=$resp"
	case $resp in
	*\"$listen\"*) ok=true ;;
	esac
	$ok
}

t_begin "killing succeeds" && {
	kill $pitchfork_pid
}

t_begin "check stderr" && check_stderr

t_done

#!/bin/sh
. ./test-lib.sh
t_plan 4 "configurator internals tests (from FAQ)"

t_begin "setup and start" && {
	pitchfork_setup
	cat >> $pitchfork_config <<EOF
HttpRequest::DEFAULTS["rack.url_scheme"] = "https"
Configurator::DEFAULTS[:logger].formatter = Logger::Formatter.new
EOF
	pitchfork_spawn -c $pitchfork_config env.ru
	pitchfork_wait_start
}

t_begin "single request" && {
	curl -sSfv http://$listen/ | grep '"rack.url_scheme"=>"https"'
}

t_begin "killing succeeds" && {
	kill $pitchfork_pid
}

t_begin "no errors" && check_stderr

t_done

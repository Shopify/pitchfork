#!/bin/sh
. ./test-lib.sh

t_plan 3 "config.ru inside alt working_directory"

t_begin "setup and start" && {
	unicorn_setup
	rtmpfiles unicorn_config_tmp
	rm -rf $t_pfx.app
	mkdir $t_pfx.app

	cat > $t_pfx.app/config.ru <<EOF
#\--host $host --port $port
use Rack::ContentLength
use Rack::ContentType, "text/plain"
run lambda { |env| [ 200, {}, [ "#{\$master_ppid}\\n" ] ] }
EOF
	# we have --host/--port in config.ru instead
	grep -v ^listen $unicorn_config > $unicorn_config_tmp

	# the whole point of this exercise
	echo "working_directory '$t_pfx.app'" >> $unicorn_config_tmp

	# allows ppid to be 1 in before_fork
	cat >> $unicorn_config_tmp <<\EOF
before_fork do |server,worker|
  $master_ppid = Process.ppid # should be zero to detect daemonization
end
EOF

	mv $unicorn_config_tmp $unicorn_config

	unicorn_spawn -c $unicorn_config
	unicorn_wait_start
}

t_begin "hit with curl" && {
	body=$(curl -sSf http://$listen/)
}

t_begin "killing succeeds" && {
	kill $unicorn_pid
}

t_done

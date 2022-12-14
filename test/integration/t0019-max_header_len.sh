#!/bin/sh
. ./test-lib.sh
t_plan 5 "max_header_len setting (only intended for Rainbows!)"

t_begin "setup and start" && {
	pitchfork_setup
	req='GET / HTTP/1.0\r\n\r\n'
	len=$(printf "$req" | count_bytes)
	echo Pitchfork::HttpParser.max_header_len = $len >> $pitchfork_config
	pitchfork_spawn -c $pitchfork_config env.ru
	pitchfork_wait_start
}

t_begin "minimal request succeeds" && {
	rm -f $tmp
	(
		cat $fifo > $tmp &
		printf "$req"
		wait
		echo ok > $ok
	) | socat - TCP:$listen > $fifo
	test xok = x$(cat $ok)

	fgrep "HTTP/1.1 200 OK" $tmp
}

t_begin "big request fails" && {
	rm -f $tmp
	(
		cat $fifo > $tmp &
		printf 'GET /xxxxxx HTTP/1.0\r\n\r\n'
		wait
		echo ok > $ok
	) | socat - TCP:$listen > $fifo
	test xok = x$(cat $ok)
	fgrep "HTTP/1.1 413" $tmp
}

dbgcat tmp

t_begin "killing succeeds" && {
	kill $pitchfork_pid
}

t_begin "check stderr" && {
	check_stderr
}

t_done

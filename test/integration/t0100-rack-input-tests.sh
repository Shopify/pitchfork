#!/bin/sh
. ./test-lib.sh
test -r random_blob || die "random_blob required, run with 'make $0'"

t_plan 10 "rack.input read tests"

t_begin "setup and startup" && {
	rtmpfiles curl_out curl_err
	pitchfork_setup
	pitchfork_spawn -E none rack-input-tests.ru -c $pitchfork_config
	blob_sha1=$(rsha1 < random_blob)
	blob_size=$(count_bytes < random_blob)
	t_info "blob_sha1=$blob_sha1"
	pitchfork_wait_start
}

t_begin "corked identity request" && {
	rm -f $tmp
	(
		cat $fifo > $tmp &
		printf 'PUT / HTTP/1.0\r\n'
		printf 'Content-Length: %d\r\n\r\n' $blob_size
		cat random_blob
		wait
		echo ok > $ok
	) | ( sleep 1 && socat - TCP4:$listen > $fifo )
	test 1 -eq $(grep $blob_sha1 $tmp |count_lines)
	test x"$(cat $ok)" = xok
}

t_begin "corked chunked request" && {
	rm -f $tmp
	(
		cat $fifo > $tmp &
		content-md5-put < random_blob
		wait
		echo ok > $ok
	) | ( sleep 1 && socat - TCP4:$listen > $fifo )
	test 1 -eq $(grep $blob_sha1 $tmp |count_lines)
	test x"$(cat $ok)" = xok
}

t_begin "corked identity request (input#size first)" && {
	rm -f $tmp
	(
		cat $fifo > $tmp &
		printf 'PUT /size_first HTTP/1.0\r\n'
		printf 'Content-Length: %d\r\n\r\n' $blob_size
		cat random_blob
		wait
		echo ok > $ok
	) | ( sleep 1 && socat - TCP4:$listen > $fifo )
	test 1 -eq $(grep $blob_sha1 $tmp |count_lines)
	test x"$(cat $ok)" = xok
}

t_begin "corked identity request (input#rewind first)" && {
	rm -f $tmp
	(
		cat $fifo > $tmp &
		printf 'PUT /rewind_first HTTP/1.0\r\n'
		printf 'Content-Length: %d\r\n\r\n' $blob_size
		cat random_blob
		wait
		echo ok > $ok
	) | ( sleep 1 && socat - TCP4:$listen > $fifo )
	test 1 -eq $(grep $blob_sha1 $tmp |count_lines)
	test x"$(cat $ok)" = xok
}

t_begin "corked chunked request (input#size first)" && {
	rm -f $tmp
	(
		cat $fifo > $tmp &
		printf 'PUT /size_first HTTP/1.1\r\n'
		printf 'Host: example.com\r\n'
		printf 'Transfer-Encoding: chunked\r\n'
		printf 'Trailer: Content-MD5\r\n'
		printf '\r\n'
		content-md5-put --no-headers < random_blob
		wait
		echo ok > $ok
	) | ( sleep 1 && socat - TCP4:$listen > $fifo )
	test 1 -eq $(grep $blob_sha1 $tmp |count_lines)
	test 1 -eq $(grep $blob_sha1 $tmp |count_lines)
	test x"$(cat $ok)" = xok
}

t_begin "corked chunked request (input#rewind first)" && {
	rm -f $tmp
	(
		cat $fifo > $tmp &
		printf 'PUT /rewind_first HTTP/1.1\r\n'
		printf 'Host: example.com\r\n'
		printf 'Transfer-Encoding: chunked\r\n'
		printf 'Trailer: Content-MD5\r\n'
		printf '\r\n'
		content-md5-put --no-headers < random_blob
		wait
		echo ok > $ok
	) | ( sleep 1 && socat - TCP4:$listen > $fifo )
	test 1 -eq $(grep $blob_sha1 $tmp |count_lines)
	test x"$(cat $ok)" = xok
}

t_begin "regular request" && {
	curl -sSf -T random_blob http://$listen/ > $curl_out 2> $curl_err
        test x$blob_sha1 = x$(cat $curl_out)
        test ! -s $curl_err
}

t_begin "chunked request" && {
	curl -sSf -T- < random_blob http://$listen/ > $curl_out 2> $curl_err
        test x$blob_sha1 = x$(cat $curl_out)
        test ! -s $curl_err
}

dbgcat r_err

t_begin "shutdown" && {
	kill $pitchfork_pid
}

t_done

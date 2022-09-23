#!/bin/sh
. ./test-lib.sh
t_plan 9 "PrereadInput middleware tests"

t_begin "setup and start" && {
	random_blob_sha1=$(rsha1 < random_blob)
	pitchfork_setup
	pitchfork_spawn -c $pitchfork_config preread_input.ru
	pitchfork_wait_start
}

t_begin "single identity request" && {
	curl -sSf -T random_blob http://$listen/ > $tmp
}

t_begin "sha1 matches" && {
	test x"$(cat $tmp)" = x"$random_blob_sha1"
}

t_begin "single chunked request" && {
	curl -sSf -T- < random_blob http://$listen/ > $tmp
}

t_begin "sha1 matches" && {
	test x"$(cat $tmp)" = x"$random_blob_sha1"
}

t_begin "app only dispatched twice" && {
	test 2 -eq "$(grep 'app dispatch:' < $r_err | count_lines )"
}

t_begin "aborted chunked request" && {
	rm -f $tmp
	curl -sSf -T- < $fifo http://$listen/ > $tmp &
	curl_pid=$!
	kill -9 $curl_pid
	wait
}

t_begin "app only dispatched twice" && {
	test 2 -eq "$(grep 'app dispatch:' < $r_err | count_lines )"
}

t_begin "killing succeeds" && {
	kill -QUIT $pitchfork_pid
}

t_done

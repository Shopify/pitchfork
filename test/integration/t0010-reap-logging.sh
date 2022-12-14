#!/bin/sh
. ./test-lib.sh
t_plan 9 "reap worker logging messages"

t_begin "setup and start" && {
	pitchfork_setup
	cat >> $pitchfork_config <<EOF
after_fork { |s,w| File.open('$fifo','w') { |f| f.write '.' } }
EOF
	pitchfork_spawn -c $pitchfork_config pid.ru
	test '.' = $(cat $fifo)
	pitchfork_wait_start
}

t_begin "kill 1st worker=0" && {
	pid_1=$(curl http://$listen/)
	kill -9 $pid_1
}

t_begin "wait for 2nd worker to start" && {
	test '.' = $(cat $fifo)
}

t_begin "ensure log of 1st reap is an ERROR" && {
	dbgcat r_err
	grep "ERROR.*worker=0 pid=$pid_1 .*reaped" $r_err
	dbgcat r_err
}

t_begin "kill 2nd worker gracefully" && {
	pid_2=$(curl http://$listen/)
	kill -QUIT $pid_2
}

t_begin "wait for 3rd worker=0 to start " && {
	test '.' = $(cat $fifo)
}

t_begin "ensure log of 2nd reap is a INFO" && {
	grep "INFO.*worker=0.*pid=$pid_2 .*reaped" $r_err
	> $r_err
}

t_begin "killing succeeds" && {
	kill "$pitchfork_pid"
	wait
}

t_begin "check stderr" && {
	check_stderr
}

t_done

#!/bin/sh
# Copyright (c) 2009 Rainbows! hackers
# Copyright (c) 2010 Unicorn hackers
. ./my-tap-lib.sh

set +u

# sometimes we rely on http_proxy to avoid wasting bandwidth with Isolate
# and multiple Ruby versions
NO_PROXY=${UNICORN_TEST_ADDR-127.0.0.1}
export NO_PROXY

set -e
RUBY="${RUBY-ruby}"
RUBY_VERSION=${RUBY_VERSION-$($RUBY -e 'puts RUBY_VERSION')}
RUBY_ENGINE=${RUBY_ENGINE-$($RUBY -e 'puts((RUBY_ENGINE rescue "ruby"))')}
t_pfx=$PWD/trash/$T-$RUBY_ENGINE-$RUBY_VERSION
set -u

PATH=$PWD/bin:$PATH
export PATH

test -x $PWD/bin/unused_listen || die "must be run in 't' directory"

wait_for_pid () {
	path="$1"
	nr=30
	while ! test -s "$path" && test $nr -gt 0
	do
		nr=$(($nr - 1))
		sleep 1
	done
}

# "unix_time" is not in POSIX, but in GNU, and FreeBSD 9.0 (possibly earlier)
unix_time () {
	$RUBY -e 'puts Time.now.to_i'
}

# "wc -l" outputs leading whitespace on *BSDs, filter it out for portability
count_lines () {
	wc -l | tr -d '[:space:]'
}

# "wc -c" outputs leading whitespace on *BSDs, filter it out for portability
count_bytes () {
	wc -c | tr -d '[:space:]'
}

# given a list of variable names, create temporary files and assign
# the pathnames to those variables
rtmpfiles () {
	for id in "$@"
	do
		name=$id

		case $name in
		*fifo)
			_tmp=$t_pfx.$id
			eval "$id=$_tmp"
			rm -f $_tmp
			mkfifo $_tmp
			T_RM_LIST="$T_RM_LIST $_tmp"
			;;
		*socket)
			_tmp="$(mktemp -t $id.$$.XXXXXXXX)"
			if test $(printf "$_tmp" |count_bytes) -gt 108
			then
				echo >&2 "$_tmp too long, tests may fail"
				echo >&2 "Try to set TMPDIR to a shorter path"
			fi
			eval "$id=$_tmp"
			rm -f $_tmp
			T_RM_LIST="$T_RM_LIST $_tmp"
			;;
		*)
			_tmp=$t_pfx.$id
			eval "$id=$_tmp"
			> $_tmp
			T_OK_RM_LIST="$T_OK_RM_LIST $_tmp"
			;;
		esac
	done
}

dbgcat () {
	id=$1
	eval '_file=$'$id
	echo "==> $id <=="
	sed -e "s/^/$id:/" < $_file
}

check_stderr () {
	set +u
	_r_err=${1-${r_err}}
	set -u
	if grep -v $T $_r_err | grep -i Error | \
		grep -v NameError.*Pitchfork::Waiter
	then
		die "Errors found in $_r_err"
	elif grep SIGKILL $_r_err
	then
		die "SIGKILL found in $_r_err"
	fi
}

# pitchfork_setup
pitchfork_setup () {
	eval $(unused_listen)
	port=$(expr $listen : '[^:]*:\([0-9]*\)')
	host=$(expr $listen : '\([^:][^:]*\):[0-9][0-9]*')

	rtmpfiles pitchfork_config pid r_err r_out fifo tmp ok
	cat > $pitchfork_config <<EOF
listen "$listen"
EOF
}

if command -v nc > /dev/null 2>&1; then
  attempt_to_connect() {
    nc -z "${1}" "${2}" -w '1' > /dev/null 2>&1
    return $?
  }
elif command -v bash > /dev/null 2>&1; then
  attempt_to_connect() {
    # shellcheck disable=SC2086
    timeout $TIMEOUTFLAG 1 bash -c "echo < /dev/tcp/${1}/${2}" > /dev/null 2>&1
    return $?
  }
else
  attempt_to_connect() {
    echo "[WARNING] This container doesn't contain nc, we won't be able to check ${1}:${2} availability."
    return 0
  }
fi

wait_for_service() {
	port=$(expr $listen : '[^:]*:\([0-9]*\)')
	host=$(expr $listen : '\([^:][^:]*\):[0-9][0-9]*')

	local attempts=$1
	until attempt_to_connect "$host" "$port" > /dev/null 2>&1; do
		sleep 0.1
		attempts=$((attempts-1))
		if [ "${attempts}" -le 0 ]; then
			return 1 # UnavailableService
		fi
	done

	return 0
}

pitchfork_spawn () {
	(
		pitchfork "$@" 2>"$r_err" 1>"$r_out" &
		echo "$!" > "$pid"
	) &
	wait
}

pitchfork_wait_start () {
	wait_for_service 30
	pitchfork_pid=$(cat $pid)
}

rsha1 () {
	sha1sum.rb
}

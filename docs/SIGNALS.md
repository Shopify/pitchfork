## Signal handling

In general, signals need only be sent to the master process. However,
the signals Pitchfork uses internally to communicate with the worker
processes are documented here as well.

### Master Process

* `INT/TERM` - quick shutdown, kills all workers immediately

* `QUIT` - graceful shutdown, waits for workers to finish their
  current request before finishing.

* `USR1` - reopen all logs owned by the master and all workers
  See `Pitchfork::Util.reopen_logs` for what is considered a log.

* `USR2` - trigger a manual refork. A worker is promoted as
  a new mold, and existing workers progressively replaced
  by fresh ones.

* `TTIN` - increment the number of worker processes by one

* `TTOU` - decrement the number of worker processes by one

### Worker Processes

Note: the master uses a pipe to signal workers
instead of `kill(2)` for most cases.  Using signals still (and works and
remains supported for external tools/libraries), however.

Sending signals directly to the worker processes should not normally be
needed.  If the master process is running, any exited worker will be
automatically respawned.

* `INT/TERM` - Quick shutdown, immediately exit.
  The master process will respawn a worker to replace this one.
  Immediate shutdown is still triggered using kill(2) and not the
  internal pipe as of unicorn 4.8

* `QUIT` - Gracefully exit after finishing the current request.
  The master process will respawn a worker to replace this one.

* `USR1` - Reopen all logs owned by the worker process.
  See `Pitchfork::Util.reopen_logs` for what is considered a log.
  Log files are not reopened until it is done processing
  the current request, so multiple log lines for one request
  (as done by Rails) will not be split across multiple logs.

  It is NOT recommended to send the USR1 signal directly to workers via
  `killall -USR1 unicorn` if you are using user/group-switching support
  in your workers.  You will encounter incorrect file permissions and
  workers will need to be respawned.  Sending USR1 to the master process
  first will ensure logs have the correct permissions before the master
  forwards the USR1 signal to workers.

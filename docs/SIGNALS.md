## Signal handling

In general, signals need only be sent to the master process. However,
the signals Pitchfork uses internally to communicate with the worker
processes are documented here as well.

### Master Process

* `INT` - quick shutdown, kills all workers immediately

* `QUIT/TERM` - graceful shutdown, waits for workers to finish their
  current request before finishing.

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

* `INT` - Quick shutdown, immediately exit.
  The master process will respawn a worker to replace this one.
  Immediate shutdown is still triggered using kill(2) and not the
  internal pipe as of unicorn 4.8

* `QUIT/TERM` - Gracefully exit after finishing the current request.
  The master process will respawn a worker to replace this one.

## Signal handling

In general, signals need to only be sent to the monitor process. However,
the signals Pitchfork uses internally to communicate with the worker
processes are documented here as well.

### Monitor Process

* `INT` - quick shutdown, kills all workers immediately

* `QUIT/TERM` - graceful shutdown, waits for workers to finish their
  current request before finishing.

* `USR2` - trigger a manual refork. A worker is promoted as
  a new mold, and existing workers progressively replaced
  by fresh ones.

* `TTIN` - increment the number of worker processes by one

* `TTOU` - decrement the number of worker processes by one

### Worker Processes

Note: the monitor uses a pipe to signal workers
instead of `kill(2)` for most cases.  Using signals still works and
remains supported for external tools/libraries, however.

Sending signals directly to the worker processes should not normally be
needed.  If the monitor process is running, any exited worker will be
automatically respawned.

* `INT` - Quick shutdown, immediately exit.
  The monitor process will respawn a worker to replace this one.
  Immediate shutdown is triggered using kill(2).

* `QUIT/TERM` - Gracefully exit after finishing the current request.
  The monitor process will respawn a worker to replace this one.

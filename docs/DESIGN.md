## Design

* Simplicity: Pitchfork is a traditional UNIX prefork web server.
  No threads are used at all, this makes applications easier to debug
  and fix.
  
* Resiliency: If something in goes catastrophically wrong and your application
  is dead locked or somehow stuck, once the request timeout is reached the master
  process will take care of sending `kill -9` to the affected worker and
  spawn a new one to replace it.

* Leverage Copy-on-Write: The only real disadvantage of prefork servers is
  their increased memory usage. But thanks to reforking, `pitchfork` is able
  to drastically improve Copy-on-Write performance, hence reduce memory usage
  enough that it's no longer a concern.

* The Ragel+C HTTP parser is taken from Mongrel.

* All HTTP parsing and I/O is done much like Mongrel:
    1. read/parse HTTP request headers in full
    2. call Rack application
    3. write HTTP response back to the client

* Like Mongrel, neither keepalive nor pipelining are supported.
  These aren't needed since Pitchfork is only designed to serve
  fast, low-latency clients directly.  Do one thing, do it well;
  let nginx handle slow clients.

* Configuration is purely in Ruby. Ruby is less
  ambiguous than YAML and lets lambdas for
  before_fork/after_fork hooks be defined inline. An
  optional, separate config_file may be used to modify supported
  configuration changes.

* One master process spawns and reaps worker processes.

* The number of worker processes should be scaled to the number of
  CPUs or memory you have. If you have an existing
  Unicorn cluster on a single-threaded app, using the same amount of
  processes should work. Let a full-HTTP-request-buffering reverse
  proxy like nginx manage concurrency to thousands of slow clients for
  you. Pitchfork scaling should only be concerned about limits of your
  backend system(s).

* Load balancing between worker processes is done by the OS kernel.
  All workers share a common set of listener sockets and does
  non-blocking accept() on them.  The kernel will decide which worker
  process to give a socket to and workers will sleep if there is
  nothing to accept().

* Since non-blocking accept() is used, there can be a thundering
  herd when an occasional client connects when application
  *is not busy*.  The thundering herd problem should not affect
  applications that are running all the time since worker processes
  will only select()/accept() outside of the application dispatch.

* Additionally, thundering herds are much smaller than with
  configurations using existing prefork servers.  Process counts should
  only be scaled to backend resources, _never_ to the number of expected
  clients like is typical with blocking prefork servers.  So while we've
  seen instances of popular prefork servers configured to run many
  hundreds of worker processes, Pitchfork deployments are typically between
  1 and 2 processes per-core.

* Blocking I/O is used for clients. This allows a simpler code path
  to be followed within the Ruby interpreter and fewer syscalls.

* `SIGKILL` is used to terminate the timed-out workers from misbehaving apps
  as reliably as possible on a UNIX system. The default timeout is a
  generous 20 seconds.

* The poor performance of select() on large FD sets is avoided
  as few file descriptors are used in each worker.
  There should be no gain from moving to highly scalable but
  unportable event notification solutions for watching few
  file descriptors.

* If the master process dies unexpectedly for any reason,
  workers will notice within :timeout/2 seconds and follow
  the master to its death.

* There is never any explicit real-time dependency or communication
  between the worker processes nor to the master process.
  Synchronization is handled entirely by the OS kernel and shared
  resources are never accessed by the worker when it is servicing
  a client.

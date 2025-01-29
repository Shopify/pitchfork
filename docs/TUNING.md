# Tuning pitchfork

unicorn performance is generally as good as a (mostly) Ruby web server
can provide. Most often the performance bottleneck is in the web
application running on Pitchfork rather than Pitchfork itself.

## pitchfork Configuration

See Pitchfork::Configurator for details on the config file format.
`worker_processes` is the most-commonly needed tuning parameter.

### Pitchfork::Configurator#worker_processes

* `worker_processes` should be scaled to the number of processes your
  backend system(s) can support. DO NOT scale it to the number of
  external network clients your application expects to be serving.
  unicorn is NOT for serving slow clients, that is the job of nginx.

* `worker_processes` should be *at* *least* the number of CPU cores on
  a dedicated server (unless you do not have enough memory).
  If your application has occasionally slow responses that are /not/
  CPU-intensive, you may increase this to workaround those inefficiencies.

* `Etc.nprocessors` may be used to determine the number of CPU cores present.

* Never, ever, increase `worker_processes` to the point where the system
  runs out of physical memory and hits swap. Production servers should
  never see swap activity.

* Bigger is better. The more `worker_processes` you run, the more you'll
  benefit from Copy-on-Write. If your application use 1GiB of memory after boot,
  running `10` worker processes, the relative memory usage per worker will only be
  `~100MiB`, whereas if you only run `5` worker processes, there relative usage will be
  `~200MiB`.
  So if you can chose your hardware, it's preferable to use a smaller number
  of bigger servers rather than a large number of smaller servers.
  The same applies for containers, it's preferable to run a smaller number of larger containers.

### Pitchfork::Configurator#refork_after

* Reforking allows to share again memory pages that have been written into.

* In general, the main source of shared memory pages invalidation in Ruby
  is inline caches and JITed code. This means that calling a method for the
  first time tend to degrade Copy-on-Write performance, and that over time
  as more and more codepaths get executed at least once, less and less memory
  is shared until it stabilize as most codepaths have been warmed up.

* This is why automatic reforking is based on the number of processed requests.
  You want to refork relatively frequently when the `pitchfork` server is fresh,
  and then less and less frequently over time.

### Pitchfork::Configurator#listen Options

* Setting a very low value for the :backlog parameter in "listen"
  directives can allow failover to happen more quickly if your
  cluster is configured for it.

* If you're doing extremely simple benchmarks and getting connection
  errors under high request rates, increasing your :backlog parameter
  above the already-generous default of 1024 can help avoid connection
  errors.  Keep in mind this is not recommended for real traffic if
  you have another machine to failover to (see above).

* :rcvbuf and :sndbuf parameters generally do not need to be set for TCP
  listeners under Linux 2.6 because auto-tuning is enabled.  UNIX domain
  sockets do not have auto-tuning buffer sizes; so increasing those will
  allow syscalls and task switches to be saved for larger requests
  and responses.  If your app only generates small responses or expects
  small requests, you may shrink the buffer sizes to save memory, too.

* Having socket buffers too large can also be detrimental or have
  little effect.  Huge buffers can put more pressure on the allocator
  and may also thrash CPU caches, cancelling out performance gains
  one would normally expect.

* UNIX domain sockets are slightly faster than TCP sockets, but only
  work if nginx is on the same machine.

## Kernel Parameters (Linux sysctl and sysfs)

WARNING: Do not change system parameters unless you know what you're doing!

* net.core.rmem_max and net.core.wmem_max can increase the allowed
  size of :rcvbuf and :sndbuf respectively. This is mostly only useful
  for UNIX domain sockets which do not have auto-tuning buffer sizes.

* For load testing/benchmarking with UNIX domain sockets, you should
  consider increasing net.core.somaxconn or else nginx will start
  failing to connect under heavy load.  You may also consider setting
  a higher :backlog to listen on as noted earlier.

* If you're running out of local ports, consider lowering
  net.ipv4.tcp_fin_timeout to 20-30 (default: 60 seconds).  Also
  consider widening the usable port range by changing
  net.ipv4.ip_local_port_range.

* Setting net.ipv4.tcp_timestamps=1 will also allow setting
  net.ipv4.tcp_tw_reuse=1 and net.ipv4.tcp_tw_recycle=1, which along
  with the above settings can slow down port exhaustion.  Not all
  networks are compatible with these settings, check with your friendly
  network administrator before changing these.

* Increasing the MTU size can reduce framing overhead for larger
  transfers.  One often-overlooked detail is that the loopback
  device (usually "lo") can have its MTU increased, too.

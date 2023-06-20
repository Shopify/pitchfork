# Application Timeouts

This article focuses on _application_ setup for Rack applications, but
can be expanded to all applications that connect to external resources
and expect short response times.

This article is not specific to `pitchfork`, but exists to discourage
the overuse of the built-in `timeout` directive in `pitchfork`.

## ALL External Resources Are Considered Unreliable

Network reliability can _never_ be guaranteed.  Network failures cannot
be detected reliably by the client (Rack application) in a reasonable
timeframe, not even on a LAN.

Thus, application authors must configure timeouts when interacting with
external resources.

Most database adapters allow configurable timeouts.

`Net::HTTP` and `Net::SMTP` in the Ruby standard library allow
configurable timeouts.

Even for things as fast as [memcached](https://memcached.org/),
[dalli](https://rubygems.org/gems/dalli) and other memcached clients,
all offer configurable timeouts.

Consult the relevant documentation for the libraries you use on
how to configure these timeouts.

## Timeout module in the Ruby standard library

Ruby offers a Timeout module in its standard library.  It has several
caveats and is not always reliable:

* /Some/ Ruby C extensions are not interrupted/timed-out gracefully by
  this module (report these bugs to extension authors, please) but
  pure-Ruby components should be.

* `Timeout` uses [`Thread#raise` which most code don't and probably can't
  handle properly](https://www.mikeperham.com/2015/05/08/timeout-rubys-most-dangerous-api/).
  A process in which a `Timeout.timeout` block expired
  should be considered corrupted and should exit as soon as possible.

* Long-running tasks may run inside `ensure' clauses after timeout
  fires, causing the timeout to be ineffective.

The Timeout module is a second-to-last-resort solution, timeouts using
`IO.select` (or similar) are more reliable. If you depend on libraries
that do not offer timeouts when connecting to external resources, kindly
ask those library authors to provide configurable timeouts.

### A Note About Filesystems

Most operations to regular files on POSIX filesystems are NOT
interruptible. Thus, the "timeout" module in the Ruby standard library
can not reliably timeout systems with massive amounts of iowait.

If your app relies on the filesystem, ensure all the data your
application works with is small enough to fit in the kernel page cache.
Otherwise increase the amount of physical memory you have to match, or
employ a fast, low-latency storage system (solid state).

Volumes mounted over NFS (and thus a potentially unreliable network)
must be mounted with timeouts and applications must be prepared to
handle network/server failures.

## The Last Line Of Defense

The `timeout` mechanism in pitchfork is an extreme solution that should
be avoided whenever possible.
It will help preserve the platform if your application or a dependency
has a bug that cause it to either get stuck or be too slow, but it is not a
solution to such bugs, merely a mitigation.

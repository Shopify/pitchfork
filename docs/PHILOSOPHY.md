# The Philosophy Behind pitchfork

## Avoid Complexity

Instead of attempting to be efficient at serving slow clients, pitchfork
relies on a buffering reverse proxy to efficiently deal with slow
clients.

## Threads and Events Are Not Well Suited For Transactional Web Applications

`pitchfork` uses a preforking worker model with blocking I/O.
Our processing model is the antithesis of processing models using threads or
non-blocking I/O with events or fibers.

It is only meant to serve fast, transactional HTTP/1.1 applications.
These applications rarely if ever spend more than half their time on IOs, and
any remote API call made by the application should either have a strict SLA
and timeout, or be deferred to a background job processing system.

As such, when they are ran in a threaded or fiber processing model, they suffer
from GVL contention and GC pauses, which hurts latency.

`pitchfork` is not suited for all applications. `pitchfork` is optimized for
applications that are CPU/memory/disk intensive and spend little time
waiting on external resources (e.g. a database server or external API).

WebSocket, Server-Sent Events and applications that mainly act as a light proxy
to another service have radically different performance profiles and requirements,
and shouldn't be handled by the same process. It's preferable to host these with
a threaded or evented processing model (`falcon`, `puma`, etc).

No processing model can efficiently handle both types of workload. Use
the right tool with the right configuration for the right job.

## Improved Performance Through Reverse Proxying

By acting as a buffer to shield unicorn from slow I/O, a reverse proxy
will inevitably incur overhead in the form of extra data copies.
However, as I/O within a local network is fast (and faster still
with local sockets), this overhead is negligible for the vast majority
of HTTP requests and responses.

The ideal reverse proxy complements the weaknesses of `pitchfork`.
A reverse proxy for `pitchfork` should meet the following requirements:

1. It should fully buffer all HTTP requests (and large responses).
   Each request should be "corked" in the reverse proxy and sent
   as fast as possible to the backend unicorn processes.  This is
   the most important feature to look for when choosing a
   reverse proxy for `pitchfork`.

2. It should handle SSL/TLS termination. Requests should arrive
   decrypted to `pitchfork`. Reverse proxy can do this much more
   efficiently. If you don't trust your local network enough to
   make unencrypted traffic go through it, you can have a reverse
   proxy on the same server than `pitchfork` to handle decryption.

3. It should handle HTTP/2 or HTTP/3 termination. Newer HTTP protocols
   do not provide any feature or improvements that are useful or even desirable
   for transactional HTTP applications. Your reverse proxy or load balancer
   should handle the HTTP/2 or HTTP/3 protocol with the client, but forward
   requests to `pitchfork` as HTTP/1.1.

4. It should efficiently manage persistent connections (and
   pipelining) to slow clients.

5. It should not be "sticky". Even if the client has a persistent
   connection, every request made as part of that persistent connection
   should be load balanced individually.

6. It should (optionally) serve static files. If you have static
   files on your site (especially large ones), they are far more
   efficiently served with as few data copies as possible (e.g. with
   sendfile() to completely avoid copying the data to userspace).

Suitable options include `nginx`, `caddy` and likely several others.

## Leverage Copy-on-Write to reduce memory usage.

One of the main advantages of threaded servers over preforking servers is their
lower memory usage.

However `pitchfork` solves this with its reforking feature. If enabled and properly configured
it very significantly increase Copy-on-Write performance, closing the gap with threaded servers.

## Assume Modern Depoyment Methods

Pitchfork assumes it is deployed using modern tools such as either containers or
advanced init systems such as systemd. As such it doesn't provide classic daemon
functionaly like pidfile management, log rediction and reopening, config reloading etc.

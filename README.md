# pitchfork: Rack HTTP server for shared-nothing architecture

`pitchfork` is a preforking HTTP server for Rack applications designed
to minimize memory usage by maximizing Copy-on-Write performance.

Like [`unicorn`](https://yhbt.net/unicorn/README.html) (of which `pitchfork` is a derivative), it is designed to
only serve fast clients on low-latency, high-bandwidth connections and take
advantage of features in Unix/Unix-like kernels. Slow clients should
only be served by placing a reverse proxy capable of fully buffering
both the request and response in between `pitchfork` and slow clients.

## Features

* Designed for Rack, Linux, fast clients, and ease-of-debugging. We
  cut out everything that is better supported by the operating system,
  [nginx](https://nginx.org/) or [Rack](https://rack.github.io/).

* Shared-Nothing architecture: workers all run within their own isolated
  address space and only serve one client at a time for maximum performance
  and robustness. Concurrent requests don't need to compete for the GVL,
  or impact each other's latency when triggering garbage collection.
  It also does not care if your application is thread-safe or not.

* Reforking: `pitchfork` can be configured to periodically promote a warmed-up worker
  as the new template from which workers are forked. This dramatically improves
  the proportion of shared memory, making processes use only marginally more
  memory than threads would.

* Compatible with Ruby 2.5.0 and later.

* Process management: `pitchfork` will reap and restart workers that
  die from broken apps. There is no need to manage multiple processes
  or ports yourself. `pitchfork` can spawn and manage any number of
  worker processes you choose to scale your backend to.

* Adaptative timeout: request timeouts can be extended dynamically on a
  per-request basis, which allows you to keep a strict overall timeout for
  most endpoints, but allow a few endpoints to take longer.

* Load balancing is done entirely by the operating system kernel.
  Requests never pile up behind a busy worker process.

## When to Use

Pitchfork isn't inherently better than other Ruby application servers; it mostly
focuses on different tradeoffs.

If you are fine with your current server, it's best to stick with it.

If there is a problem you are trying to solve, please read the
[migration guide](docs/WHY_MIGRATE.md) first.

## Requirements

Ruby(MRI) Version 2.5 or above.

`pitchfork` can be used on any Unix-like system, however the reforking
feature requires `PR_SET_CHILD_SUBREAPER` which is a Linux 3.4 (May 2012) feature.

## Installation

Add this line to your application's Gemfile:

```ruby
gem "pitchfork"
```

And then execute:

```bash
$ bundle install
```

Or install it yourself as:

```
$ gem install pitchfork
```

## Usage

### Rack

In your application root directory, run:

```bash
$ bundle exec pitchfork
```

`pitchfork` will bind to all interfaces on TCP port 8080 by default.
You may use the `--listen` switch to bind to a different
address:port or a UNIX socket.

### Configuration File(s)

`pitchfork` will look for the config.ru file used by rackup in `APP_ROOT`.

For deployments, it can use a config file for pitchfork-specific options
specified by the `--config-file/-c` command-line switch.
See the [configuration documentation](docs/CONFIGURATION.md) for the syntax
of the pitchfork-specific options.

The default settings are designed for maximum out-of-the-box
compatibility with existing applications.

Most command-line options for other Rack applications (above) are also
supported.  Run `pitchfork -h` to see command-line options.

## Relation to Unicorn

Pitchfork initially started as a Unicorn patch, however some Unicorn features
as well as the Unicorn policy of supporting extremely old Ruby version made it challenging.

Forking was the occasion to significantly reduce the complexity.

However some large parts of Pitchfork like the HTTP parser are still mostly unchanged from Unicorn, and Unicorn
is fairly stable these days. As such we aim to backport any Unicorn patches that may apply to Pitchfork and vice versa.

## License

pitchfork is copyright 2022 Shopify Inc and all contributors.
It is based on Unicorn 6.1.0.

Unicorn is copyright 2009-2018 by all contributors (see logs in git).
It is based on Mongrel 1.1.5.
Mongrel is copyright 2007 Zed A. Shaw and contributors.

pitchfork is licensed under the GPLv2 or later or Ruby (1.8)-specific terms.
See the included LICENSE file for details.

## Thanks

Thanks to Eric Wong and all Unicorn and Mongrel contributors over the years.
Pitchfork would have been much harder to implement otherwise.

Thanks to Will Jordan who implemented Puma's "fork worker" experimental feature
which has been a significant inspiration for Pitchfork.

Thanks to Peter Bui for letting us use the `pitchfork` name on Rubygems.

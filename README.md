# pitchfork: Rack HTTP server for shared-nothing architecture

`pitchfork` is a preforking HTTP server for Rack applications designed
to minimize memory usage by maximizing Copy-on-Write performance.

Like [`unicorn`](https://yhbt.net/unicorn/README.html) (which `pitchfork` is a derivative of), it is designed to
only serve fast clients on low-latency, high-bandwidth connections and take
advantage of features in Unix/Unix-like kernels. Slow clients should
only be served by placing a reverse proxy capable of fully buffering
both the request and response in between `pitchfork` and slow clients.

## Disclaimer

Until this notice is removed from the README, `pitchfork` should be
considered experimental. As such it is not encouraged to run it in
production just yet unless you feel capable of debugging yourself
any issue that may arise.

## Features

* Designed for Rack, Linux, fast clients, and ease-of-debugging. We
  cut out everything that is better supported by the operating system,
  [nginx](https://nginx.org/) or [Rack](https://rack.github.io/).

* Shared-Nothing architecture: workers all run within their own isolated
  address space and only serve one client at a time for maximum performance
  and robustness. Concurrent requests don't need to compete for the GVL,
  or impact each others latency when triggering garbage collection.
  It also does not care if your application is thread-safe or not.

* Reforking: `pitchfork` can be configured to periodically promote a warmed up worker
  as the new template from which workers are forked. This dramatically improves
  the proportion of shared memory, making processes use only marginally more
  memory than threads would.

* Compatible with Ruby 2.5.0 and later.

* Process management: `pitchfork` will reap and restart workers that
  die from broken apps. There is no need to manage multiple processes
  or ports yourself. `pitchfork` can spawn and manage any number of
  worker processes you choose to scale to your backend.

* Load balancing is done entirely by the operating system kernel.
  Requests never pile up behind a busy worker process.

## Requirements

Ruby(MRI) Version 2.5 and above.

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

`pitchfork` will look for the config.ru file used by rackup in APP_ROOT.

For deployments, it can use a config file for pitchfork-specific options
specified by the `--config-file/-c` command-line switch.
See the [configuration documentation](docs/CONFIGURATION.md) for the syntax
of the pitchfork-specific options.

The default settings are designed for maximum out-of-the-box
compatibility with existing applications.

Most command-line options for other Rack applications (above) are also
supported.  Run `pitchfork -h` to see command-line options.

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
which have been a significant inspiration for Pitchfork.

Thanks to Peter Bui for letting us use the `pitchfork` name on Rubygems.

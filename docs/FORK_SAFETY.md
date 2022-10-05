# Fork Safety

Because `pitchfork` is a preforking server, your application code and libraries
must be fork safe.

Generally code might be fork-unsafe for one of two reasons

## Inherited Connection

When a process is forked, any open file descriptor (sockets, files, pipes, etc)
end up shared between the parent and child process. This is never what you
want, so any code keeping persistent connections should close them either
before or after the fork happens.

`pitchfork` provide two callbacks in its configuration file to do so:

```ruby
# pitchfork.conf.rb

before_fork do
  Sequel::DATABASES.each(&:disconnect)
end

after_fork do
  SomeLibary.connection.close
end
```

The documentation of any database client or network library you use should be
read with care to figure out how to disconnect it, and whether it is best to
do it before or after fork.

Since the most common Ruby application servers `Puma`, `Unicorn` and `Passenger`
have forking at least as an option, the requirements are generally well documented.

However what is novel with `Pitchfork`, is that processes can be forked more than once.
So just because an application works fine with existing pre-fork servers doesn't necessarily
mean it will work fine with `Pitchfork`.

It's not uncommon for applications to not close connections after fork, but for it to go
unnoticed because these connections are lazily created when the first request is handled.

So if you enable reforking for the first time, you may discover some issues.

Also note that rather than to expose a callback, some libraries take on them to detect
that a fork happened, and automatically close inherited connections.

## Background Threads

When a process is forked, only the main threads will stay alive in the child process.
So any libraries that spawn a background thread for periodical work may need to be notified
that a fork happened and that it should restart its thread.

Just like with connections, some libraries take on them to automatically restart their background
thread when they detect a fork happened.

# Refork Safety

Some code might happen to work without issue in other forking servers such as Unicorn or Puma,
but not work in Pitchfork when reforking is enabled.

This is because it is not uncommon for network connections or background threads to only be
initialized upon the first request. As such they're not inherited on the first fork.

However when reforking is enabled, new processes as forked out of warmed up process, as such
any lazily created connection is much more likely to have been created.

As such, if you enable reforking for the first time, it is heavily recommended to first do it
in some sort of staging environment, or on a small subset of production servers as to limit the
impact of discovering such bug.

## Known Incompatible Gems

- [The `grpc` isn't fork safe](https://github.com/grpc/grpc/issues/8798) and doesn't provide any before or after fork callback to re-establish connection.
  It can only be used in forking environment if the client is never used in the parent before fork.
  If you application uses `grpc`, you shouldn't enable reforking.
  But frankly, that gem is such a tire fire, you shouldn't use it regardless.
  If you really have to consume a gRPC API, you can consider `grpc_kit` as a replacement.

No other gem is known to be incompatible, but if you find one please open an issue to add it to the list.

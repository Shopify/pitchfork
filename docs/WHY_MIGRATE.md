# Why migrate to Pitchfork?

First and foremost, if you don't have any specific problem with your current server, then don't.

Pitchfork isn't a silver bullet, it's a very opinionated software that focus on very specific tradeoffs,
that are different from other servers.

## Coming from Unicorn

### Why Migrate?

#### Adaptative timeout

Pitchfork allows to extend the request timeout on a per request basis,
this can be helpful when trying to reduce the global request timeout
to a saner value. You can enforce a stricter value, and extend it
in the minority of offending endpoints.

#### Memory Usage - Reforking

If you are unsatisfied with Unicorn memory usage, but threaded Puma isn't an option
for you, then Pitchfork may be an option if you are able to enable reforking.

However be warned that making an application fork safe can be non-trivial,
and mistakes can lead to critical bugs.

#### Rack 3

As of Unicorn `6.1.0`, Rack 3 isn't yet supported by Unicorn.

Pitchfork is compatible with Rack 3.

### Why Not Migrate?

#### Reduced Features

While Pitchfork started as a fork of Unicorn, many features such as daemonization,
pid file management, hot reload have been stripped.

Pitchfork only kept features that makes sense in a containerized world.

### Migration Guide

If the above points convinced you to make the switch, take a look at the [migration guide](MIGRATING_FROM_UNICORN.md).
It will go over the most common changes you will need to make to use Pitchfork.

## Coming from Puma

Generally speaking, compared to (threaded) Puma, Pitchfork *may* offer better latency and isolation at the expense of throughput.

### Why Migrate?

#### Latency

If you suspect your application is subject to contention on the GVL or some other in-process shared resources,
then Pitchfork may offer improved latency.

It is however heavily recommended to first confirm this suspicion with profiling
tools such as [gvltools](https://github.com/Shopify/gvltools).

If you application isn't subject to in-process contention, Pitchfork is unlikely to improve latency.

#### Out of Band Garbage Collection

Another advantage of only processing a single request per process is that
[it allows to periodically trigger garbage collection when the worker isn't processing any request](https://shopify.engineering/adventures-in-garbage-collection).

This can significantly improve tail latency at the expense of throughput.

#### Resiliency and Isolation

Since Pitchfork workers have their own address space and only process one request at a time
it makes it much harder for one faulty request to impact another.

Even if a bug causes Ruby to crash, only the request that triggered the bug will be impacted.

If a bug causes Ruby to hang, the monitor process will SIGKILL the worker and the capacity will be
reclaimed.

This makes Pitchfork more resilient to some classes of bugs.

#### Thread Safety

Pitchfork doesn't require applications to be thread-safe. That is probably the worst reason
to migrate though.

### Why Not Migrate?

#### Memory Usage

Without reforking enabled Pitchfork will without a doubt use more memory than threaded Puma.

With reforking enabled, results will vary based on the application profile and the number of Puma threads,
but should be in the same ballpark, sometimes better, but likely worse, this depends on many variables and
can't really be predicted.

However be warned that [making an application fork safe](FORK_SAFETY.md) can be non-trivial,
and mistakes can lead to critical bugs.

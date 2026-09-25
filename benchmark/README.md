# Benchmarks

## Copy on Write Efficiency

This benchmark aimed to compare real memory usage of different servers.

For instance, Puma 2 workers + 2 threads:

```bash
$ PORT=9292 bundle exec benchmark/cow_benchmark.rb puma -w 2 -t 2 --preload
Booting server...
Warming the app with ab...
Memory Usage:
Single Worker Memory Usage: 207.5 MiB
Total Cluster Memory Usage: 601.6 MiB
```

Pitchfork 4 workers:

```bash
$ PORT=8080 bundle exec benchmark/cow_benchmark.rb pitchfork -c examples/pitchfork.conf.minimal.rb 
Booting server...
Warming the app with ab...
Memory Usage:
Single Worker Memory Usage: 62.6 MiB
Total Cluster Memory Usage: 320.3 MiB
```

The `constant_caches.ru` application is specifically crafted to demonstrate how shared memory regions
get invalidated as applications execute more and more code.

It is an extreme example for benchmark purposes.

## Request processing throughput

`request_benchmark.rb` benchmarks the per-request Ruby-level hot path (HTTP parsing and
response writing) over a socket pair, without the noise of a real TCP stack or listener loop:

```bash
$ bundle exec benchmark/request_benchmark.rb
process request (parse+respond)    125.745k (± 2.9%) i/s    (7.95 μs/i)
```

Pass `profile` (and optionally an iteration count) to capture a StackProf wall-clock profile instead:

```bash
$ bundle exec benchmark/request_benchmark.rb profile
$ bundle exec stackprof benchmark/stackprof-request_benchmark.dump --text
```

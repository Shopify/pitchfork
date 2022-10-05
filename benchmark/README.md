# Benchmarks

## Copy on Write Efficiency

This benchmark aimed to compare real memory usage of differnet servers.

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

# Performance work

## Testing environment

This is all done in Docker Desktop running in WSL mode, so this is performance within a container. We're more interested in the speedups that are achieved, rather than raw performance.

The input is all generated (ie. the generator plugin), with a uniform and small distribution (ie. not very realistic). There should be no disk IO; the only process overhead would be the internal-to-container network communication with memcached and any context switching between logstash workers, memcached, and the experiment machinery that collects statistics.

## Benchmark default settings, memcached tcp 127.0.0.1

Default settings

Starting pipeline {:pipeline_id=>"main", "pipeline.workers"=>16, "pipeline.batch.size"=>125, "pipeline.batch.delay"=>50, "pipeline.max_inflight"=>2000

No batching, each worker sharing the client.

After a while of warming up, performance looks like this, and doesn't seem to get any better:

5168.78 μs per event, 5.1 keps
3451.08 μs per event, 4.9 keps
3579.53 μs per event, 5.4 keps
4080.44 μs per event, 2.2 keps
8738.50 μs per event, 2.0 keps
11832.00 μs per event, 1.5 keps
4933.07 μs per event, 5.1 keps
4186.11 μs per event, 2.4 keps

## With a basic LRU cache that is hit 100% of the time

678.78 μs per event, 26.2 keps
762.77 μs per event, 23.1 keps
776.40 μs per event, 22.4 keps
558.84 μs per event, 31.1 keps
315.19 μs per event, 54.6 keps
639.12 μs per event, 28.2 keps
646.99 μs per event, 24.9 keps

That's a great speedup, but still much slower than I would have hoped, but let's see what we can achieve when workers don't have to contend for access to the same cache.

## Uses a thread-local client to avoid contention

0.20 μs per event, 59.9 keps
0.14 μs per event, 57.2 keps
0.02 μs per event, 57.8 keps
0.10 μs per event, 57.4 keps
0.07 μs per event, 56.9 keps
0.07 μs per event, 56.8 keps
0.10 μs per event, 58.6 keps
0.21 μs per event, 57.2 keps

Very consistent and significant performance gain in terms of EPS. To go further would likely involve making this a pure Java plugin, or to this plugin use the multi_filter part of the Event API.

Not quite sure what to make of the per event timing, other than the source data from the API is in milliseconds, so as we go into microsecond and nanosecond territory, it becomes less and less useful. The kEPS should still be quite valid, so rely on that, and ignore the 'μs per event' (maybe one day there will be a more suitable unit of time measurement via the API, who
knows?)

## Reforking

Reforking is `pitchfork`'s main feature. To understand how it works, you must first understand Copy-on-Write.

### Copy-on-Write

In old UNIX systems of the ’70s or ’80s, forking a process involved copying its entire addressable memory over
to the new process address space, effectively doubling the memory usage. But since the mid ’90s, that’s no longer
true as, most, if not all, fork implementations are now sophisticated enough to trick the processes into thinking
they have their own private memory regions, while in reality they’re sharing it with other processes.

When the child process is forked, its pages tables are initialized to point to the parent’s memory pages. Later on,
if either the parent or the child tries to write in one of these pages, the operating system is notified and will
actually copy the page before it’s modified.

This means that if neither the child nor the parent write in these shared pages after the fork happens,
forked processes are essentially free.

### Shared Memory Invalidation in Ruby

So in theory, preforking servers shouldn't use more memory than threaded servers.

However, in a Ruby process, there is generally a lot of memory regions that are lazily initialized.
This include the Ruby Virtual Machine inline caches, JITed code if you use YJIT, and also
some common patterns in applications, such as memoization:

```ruby
module MyCode
  def self.some_data
    @some_data ||= File.read("path/to/something")
  end
end
```

However, since workers are forked right after boot, most codepaths have never been executed,
so most of these caches are not yet initialized.

As more code get executed, more an more memory pages get invalidated. If you were to graph the ratio
of shared memory of a ruby process over time, you'd likely see a logarithmic curve, with a quick degradation
during the first few processed request as the most common code paths get warmed up, and then a stabilization.

### Reforking

That is where reforking helps. Since move of these invalidations only happens when a codepath is executed for the
first time, if you take a warmed up worker out of rotation, and use it to fork new workers, warmed up pages will
be shared again, and most of them won't be invalidated anymore.


When you start `pitchfork` it forks the desired amount of workers:

```
PID   COMMAND
100   \_ pitchfork master
101       \_ pitchfork worker[0] (gen:0)
102       \_ pitchfork worker[1] (gen:0)
103       \_ pitchfork worker[2] (gen:0)
104       \_ pitchfork worker[3] (gen:0)
```

When a reforking is triggered, one of the workers is selected to become a `mold`, and is taken out of rotation.
When promoted, molds no longer process any incoming HTTP requests, they become inactive:

```
PID   COMMAND
100   \_ pitchfork master
101       \_ pitchfork mold (gen:1)
102       \_ pitchfork worker[1] (gen:0)
103       \_ pitchfork worker[2] (gen:0)
104       \_ pitchfork worker[3] (gen:0)
```

When a new mold has been promoted, `pitchfork` starts a slow rollout of older workers and replace them with fresh workers
forked from the mold:

```
PID   COMMAND
100   \_ pitchfork master
101       \_ pitchfork mold (gen:1)
105       \_ pitchfork worker[0] (gen:1)
102       \_ pitchfork worker[1] (gen:0)
103       \_ pitchfork worker[2] (gen:0)
104       \_ pitchfork worker[3] (gen:0)
```

```
PID   COMMAND
100   \_ pitchfork master
101       \_ pitchfork mold (gen:1)
105       \_ pitchfork worker[0] (gen:1)
106       \_ pitchfork worker[1] (gen:1)
103       \_ pitchfork worker[2] (gen:0)
104       \_ pitchfork worker[3] (gen:0)
```

etc.

### Forking Sibling Processes 

Normally on unix systems, when calling `fork(2)`, the newly created process is a child of the original one, so forking from the mold should create
a process tree such as:

```
PID   COMMAND
100   \_ pitchfork master
101       \_ pitchfork mold (gen:1)
105          \_ pitchfork worker[0] (gen:1)
```

However the `pitchfork` master process registers itself as a "child subreaper" via [`PR_SET_CHILD_SUBREAPER`](https://man7.org/linux/man-pages/man2/prctl.2.html).
This means any descendant process that is orphaned will be re-parented as a child of the master rather than a child of the init process (pid 1).

With this in mind, the mold fork twice to create an orphaned process that will get re-attached to the master, effectively forking a sibling rather than a child.
The need for `PR_SET_CHILD_SUBREAPER` is the main reason why reforking is only available on Linux. 

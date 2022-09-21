# -*- encoding: binary -*-
require "raindrops"

module Unicorn
  # This class and its members can be considered a stable interface
  # and will not change in a backwards-incompatible fashion between
  # releases of unicorn.  Knowledge of this class is generally not
  # not needed for most users of unicorn.
  #
  # Some users may want to access it in the before_fork/after_fork hooks.
  # See the Unicorn::Configurator RDoc for examples.
  class Worker
    # :stopdoc:
    @generation = 0
    class << self
      attr_accessor :generation
    end
    attr_accessor :nr, :switched, :pid, :generation
    attr_reader :master

    PER_DROP = Raindrops::PAGE_SIZE / Raindrops::SIZE
    DROPS = []

    def initialize(nr, pid: nil)
      drop_index = nr / PER_DROP
      @raindrop = DROPS[drop_index] ||= Raindrops.new(PER_DROP)
      @offset = nr % PER_DROP
      @raindrop[@offset] = 0
      @nr = nr
      @pid = pid
      @generation = self.class.generation
      @mold = false
      @switched = false
      @to_io = @master = nil
    end

    def update(message)
      self.pid = message.pid
      self.nr = message.nr
      self.generation = message.generation
      case message
      when Message::WorkerSpawned
        @master = MessageSocket.new(message.pipe)
      end
    end

    def register_to_master(control_socket)
      @to_io, @master = Unicorn.socketpair
      message = Message::WorkerSpawned.new(@nr, Process.pid, generation, @master)
      control_socket.sendmsg(message)
      @master.close
    end

    def acknowlege_promotion(control_socket)
      message = Message::WorkerPromoted.new(@nr, Process.pid, generation)
      control_socket.sendmsg(message)
    end

    def spawn_worker(worker)
      success = false
      begin
        case @master.sendmsg_nonblock(Message::SpawnWorker.new(worker.nr), exception: false)
        when :wait_writable
        else
          success = true
        end
      rescue Errno::EPIPE
        # worker will be reaped soon
      end
      success
    end

    def promote!
      @mold = true
      @generation = self.class.generation += 1
    end

    def mold?
      @mold
    end

    def to_io # IO.select-compatible
      @to_io.to_io
    end

    # master fakes SIGQUIT using this
    def quit # :nodoc:
      @master = @master.close if @master
    end

    def master=(socket)
      @master = MessageSocket.new(socket)
    end

    # call a signal handler immediately without triggering EINTR
    # We do not use the more obvious Process.kill(sig, $$) here since
    # that signal delivery may be deferred.  We want to avoid signal delivery
    # while the Rack app.call is running because some database drivers
    # (e.g. ruby-pg) may cancel pending requests.
    def fake_sig(sig) # :nodoc:
      old_cb = trap(sig, "IGNORE")
      old_cb.call
    ensure
      trap(sig, old_cb)
    end

    # master sends fake signals to children
    def soft_kill(sig) # :nodoc:
      case sig
      when Integer
        signum = sig
      else
        signum = Signal.list[sig.to_s] or
            raise ArgumentError, "BUG: bad signal: #{sig.inspect}"
      end

      # Do not care in the odd case the buffer is full, here.
      begin
        @master.sendmsg_nonblock(Message::SoftKill.new(signum), exception: false)
      rescue Errno::EPIPE
        # worker will be reaped soon
      end
    end

    # this only runs when the Rack app.call is not running
    # act like a listener
    def accept_nonblock(exception: nil) # :nodoc:
      loop do
        case buf = @to_io.recvmsg_nonblock(exception: false)
        when :wait_readable # keep waiting
          return false
        when nil # EOF master died, but we are at a safe place to exit
          fake_sig(:QUIT)
        end

        case buf
        when Message::SoftKill
          # trigger the signal handler
          fake_sig(buf.signum)
          # keep looping, more signals may be queued
        when Message
          return buf
        else
          raise TypeError, "Unexpected read_nonblock returns: #{buf.inspect}"
        end
      end # loop, as multiple signals may be sent
    end

    # worker objects may be compared to just plain Integers
    def ==(other_nr) # :nodoc:
      @nr == other_nr
    end

    # called in the worker process
    def tick=(value) # :nodoc:
      @raindrop[@offset] = value
    end

    # called in the master process
    def tick # :nodoc:
      @raindrop[@offset]
    end

    # called in both the master (reaping worker) and worker (SIGQUIT handler)
    def close # :nodoc:
      @master.close if @master
      @to_io.close if @to_io
    end
  end
end

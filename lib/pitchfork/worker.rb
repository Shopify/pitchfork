# -*- encoding: binary -*-
require 'pitchfork/shared_memory'

module Pitchfork
  # This class and its members can be considered a stable interface
  # and will not change in a backwards-incompatible fashion between
  # releases of pitchfork.  Knowledge of this class is generally not
  # not needed for most users of pitchfork.
  #
  # Some users may want to access it in the after_worker_fork/after_mold_fork hooks.
  # See the Pitchfork::Configurator RDoc for examples.
  class Worker
    # :stopdoc:
    EXIT_SIGNALS = [:QUIT, :TERM]
    attr_accessor :nr, :pid, :generation
    attr_reader :master, :requests_count

    def initialize(nr, pid: nil, generation: 0)
      @nr = nr
      @pid = pid
      @generation = generation
      @mold = false
      @to_io = @master = nil
      @exiting = false
      @requests_count = 0
      if nr
        @deadline_drop = SharedMemory.worker_tick(nr)
      else
        promoted!
      end
    end

    def meminfo
      @meminfo ||= MemInfo.new(pid) if pid
    end

    def refresh
      meminfo&.update
    end

    def exiting?
      @exiting
    end

    def pending?
      @master.nil?
    end

    def outdated?
      SharedMemory.current_generation > @generation
    end

    def update(message)
      message.class.members.each do |member|
        send("#{member}=", message.public_send(member))
      end
    end

    def register_to_master(control_socket)
      create_socketpair!
      message = Message::WorkerSpawned.new(@nr, @pid, generation, @master)
      control_socket.sendmsg(message)
      @master.close
    end

    def start_promotion(control_socket)
      create_socketpair!
      message = Message::MoldSpawned.new(@nr, @pid, generation, @master)
      control_socket.sendmsg(message)
      @master.close
    end

    def finish_promotion(control_socket)
      message = Message::MoldReady.new(@nr, @pid, generation)
      control_socket.sendmsg(message)
      SharedMemory.current_generation = @generation
    end

    def promote(generation)
      send_message_nonblock(Message::PromoteWorker.new(generation))
    end

    def spawn_worker(new_worker)
      send_message_nonblock(Message::SpawnWorker.new(new_worker.nr))
    end

    def promote!
      @generation += 1
      promoted!
    end

    def promoted!
      @mold = true
      @nr = nil
      @deadline_drop = SharedMemory.mold_tick
      self
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
      signum = Signal.list[sig.to_s] or raise ArgumentError, "BUG: bad signal: #{sig.inspect}"

      # Do not care in the odd case the buffer is full, here.
      success = send_message_nonblock(Message::SoftKill.new(signum))
      if success && EXIT_SIGNALS.include?(sig)
        @exiting = true
      end
      success
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
          return false
        when Message::SoftKill
          # trigger the signal handler
          fake_sig(buf.signum)
          # keep looping, more signals may be queued
        when Message
          return buf
        else
          raise TypeError, "Unexpected recvmsg_nonblock returns: #{buf.inspect}"
        end
      end # loop, as multiple signals may be sent
    rescue Errno::ECONNRESET
      nil
    end

    # worker objects may be compared to just plain Integers
    def ==(other) # :nodoc:
      super || (!@nr.nil? && @nr == other)
    end

    def update_deadline(timeout)
      self.deadline = Pitchfork.time_now(true) + timeout
    end

    # called in the worker process
    def deadline=(value) # :nodoc:
      @deadline_drop.value = value
    end

    # called in the master process
    def deadline # :nodoc:
      @deadline_drop.value
    end

    def reset
      @requests_count = 0
    end

    def increment_requests_count(by = 1)
      @requests_count += by
    end

    # called in both the master (reaping worker) and worker (SIGQUIT handler)
    def close # :nodoc:
      @master.close if @master
      @to_io.close if @to_io
    end

    def create_socketpair!
      @to_io, @master = Pitchfork.socketpair
    end

    def after_fork_in_child
      @master&.close
    end

    private

    def pipe=(socket)
      @master = MessageSocket.new(socket)
    end

    def send_message_nonblock(message)
      success = false
      begin
        case @master.sendmsg_nonblock(message, exception: false)
        when :wait_writable
        else
          success = true
        end
      rescue Errno::EPIPE, Errno::ECONNRESET, Errno::ECONNREFUSED
        # worker will be reaped soon
      end
      success
    end
  end
end

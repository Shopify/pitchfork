# -*- encoding: binary -*-
require "raindrops"

module Pitchfork
  # This class and its members can be considered a stable interface
  # and will not change in a backwards-incompatible fashion between
  # releases of pitchfork.  Knowledge of this class is generally not
  # not needed for most users of pitchfork.
  #
  # Some users may want to access it in the before_fork/after_fork hooks.
  # See the Pitchfork::Configurator RDoc for examples.
  class Worker
    # :stopdoc:
    EXIT_SIGNALS = [:QUIT, :TERM]
    @generation = 0
    attr_accessor :nr, :pid, :generation
    attr_reader :master

    def initialize(nr, pid: nil, generation: 0)
      @nr = nr
      @pid = pid
      @generation = generation
      @mold = false
      @to_io = @master = nil
      @exiting = false
      if nr
        build_raindrops(nr)
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

    def update(message)
      message.class.members.each do |member|
        send("#{member}=", message.public_send(member))
      end

      case message
      when Message::WorkerPromoted, Message::PromoteWorker
        promoted!
      end
    end

    def register_to_master(control_socket)
      create_socketpair!
      message = Message::WorkerSpawned.new(@nr, Process.pid, generation, @master)
      control_socket.sendmsg(message)
      @master.close
    end

    def acknowlege_promotion(control_socket)
      message = Message::WorkerPromoted.new(@nr, Process.pid, generation)
      control_socket.sendmsg(message)
    end

    def promote(generation)
      send_message_nonblock(Message::PromoteWorker.new(generation))
    end

    def spawn_worker(new_worker)
      send_message_nonblock(Message::SpawnWorker.new(new_worker.nr))
    end

    def promoted!
      @mold = true
      @nr = nil
      @drop_offset = 0
      @tick_drop = MOLD_DROP
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

    # called in the worker process
    def tick=(value) # :nodoc:
      if mold?
        MOLD_DROP[0] = value
      else
        @tick_drop[@drop_offset] = value
      end
    end

    # called in the master process
    def tick # :nodoc:
      if mold?
        MOLD_DROP[0]
      else
        @tick_drop[@drop_offset]
      end
    end

    def reset
      @requests_drop[@drop_offset] = 0
    end

    def requests_count
      @requests_drop[@drop_offset]
    end

    def increment_requests_count
      @requests_drop.incr(@drop_offset)
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
      @master.close
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
      rescue Errno::EPIPE
        # worker will be reaped soon
      end
      success
    end

    MOLD_DROP = Raindrops.new(1)
    PER_DROP = Raindrops::PAGE_SIZE / Raindrops::SIZE
    TICK_DROPS = []
    REQUEST_DROPS = []

    class << self
      # Since workers are created from another process, we have to
      # pre-allocate the drops so they are shared between everyone.
      #
      # However this doesn't account for TTIN signals that increase the
      # number of workers, but we should probably remove that feature too.
      def preallocate_drops(workers_count)
        0.upto(workers_count / PER_DROP) do |i|
          TICK_DROPS[i] = Raindrops.new(PER_DROP)
          REQUEST_DROPS[i] = Raindrops.new(PER_DROP)
        end
      end
    end

    def build_raindrops(drop_nr)
      drop_index = drop_nr / PER_DROP
      @drop_offset = drop_nr % PER_DROP
      @tick_drop = TICK_DROPS[drop_index] ||= Raindrops.new(PER_DROP)
      @requests_drop = REQUEST_DROPS[drop_index] ||= Raindrops.new(PER_DROP)
      @tick_drop[@drop_offset] = @requests_drop[@drop_offset] = 0
    end
  end
end

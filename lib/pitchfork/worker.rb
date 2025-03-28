# -*- encoding: binary -*-
# frozen_string_literal: true
require 'pitchfork/shared_memory'

module Pitchfork
  # This class and its members can be considered a stable interface
  # and will not change in a backwards-incompatible fashion between
  # releases of pitchfork.  Knowledge of this class is generally not
  # needed for most users of pitchfork.
  #
  # Some users may want to access it in the after_worker_fork/after_mold_fork hooks.
  # See the Pitchfork::Configurator RDoc for examples.
  class Worker
    # :stopdoc:
    EXIT_SIGNALS = [:QUIT, :TERM]
    attr_accessor :nr, :pid, :generation
    attr_reader :monitor, :requests_count

    def initialize(nr, pid: nil, generation: 0)
      @nr = nr
      @pid = pid
      @generation = generation
      @mold = false
      @to_io = @monitor = nil
      @exiting = false
      @requests_count = 0
      init_state
    end

    def exiting?
      @exiting
    end

    def pending?
      @monitor.nil?
    end

    def outdated?
      SharedMemory.current_generation > @generation
    end

    def update(message)
      message.class.members.each do |member|
        send("#{member}=", message.public_send(member))
      end

      case message
      when Message::MoldSpawned
        @state_drop = SharedMemory.mold_promotion_state
      when Message::MoldReady
        @state_drop = SharedMemory.mold_state
      end
    end

    def register_to_monitor(control_socket)
      create_socketpair!
      message = Message::WorkerSpawned.new(@nr, @pid, generation, @monitor)
      control_socket.sendmsg(message)
      @monitor.close
    end

    def start_promotion(control_socket)
      create_socketpair!
      message = Message::MoldSpawned.new(@nr, @pid, generation, @monitor)
      control_socket.sendmsg(message)
      @monitor.close
    end

    def finish_promotion(control_socket)
      SharedMemory.current_generation = @generation
      message = Message::MoldReady.new(@nr, @pid, generation)
      control_socket.sendmsg(message)
      @state_drop = SharedMemory.mold_state
    end

    def notify_ready(control_socket)
      self.ready = true
      message = if worker?
        Message::WorkerReady.new(@nr, @pid, @generation)
      elsif service?
        Message::ServiceReady.new(@pid, @generation)
      else
        raise "Unexpected child type"
      end

      control_socket.sendmsg(message)
    end

    def promote(generation)
      send_message_nonblock(Message::PromoteWorker.new(generation))
    end

    def spawn_worker(new_worker)
      send_message_nonblock(Message::SpawnWorker.new(new_worker.nr))
    end

    def spawn_service(_new_service)
      send_message_nonblock(Message::SpawnService.new)
    end

    def promote!(timeout)
      @generation += 1
      promoted!(timeout)
    end

    def promoted!(timeout)
      @mold = true
      @nr = nil
      @state_drop = SharedMemory.mold_promotion_state
      update_deadline(timeout) if timeout
      self
    end

    def mold?
      @mold
    end

    def service?
      false
    end

    def worker?
      !mold? && !service?
    end

    def to_io # IO.select-compatible
      @to_io.to_io
    end

    def monitor=(socket)
      @monitor = MessageSocket.new(socket)
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

    # monitor sends fake signals to children
    def soft_kill(sig) # :nodoc:
      signum = Signal.list[sig.to_s] or raise ArgumentError, "BUG: bad signal: #{sig.inspect}"

      # Do not care in the odd case the buffer is full, here.
      success = send_message_nonblock(Message::SoftKill.new(signum))
      if success && EXIT_SIGNALS.include?(sig)
        @exiting = true
      end
      success
    end

    def hard_kill(sig)
      Process.kill(sig, pid)
    end

    # this only runs when the Rack app.call is not running
    # act like a listener
    def accept_nonblock(exception: nil) # :nodoc:
      loop do
        case buf = @to_io.recvmsg_nonblock(exception: false)
        when :wait_readable # keep waiting
          return false
        when nil # EOF monitor died, but we are at a safe place to exit
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

    def ready?
      @state_drop.ready?
    end

    def ready=(bool)
      @state_drop.ready = bool
    end

    def update_deadline(timeout)
      self.deadline = Pitchfork.time_now(true) + timeout
    end

    # called in the worker process
    def deadline=(value) # :nodoc:
      # If we are (re)setting to zero mark worker as not ready.
      self.ready = false if value == 0

      @state_drop.deadline = value
    end

    # called in the monitor process
    def deadline # :nodoc:
      @state_drop.deadline
    end

    def reset
      @requests_count = 0
    end

    def increment_requests_count(by = 1)
      @requests_count += by
    end

    # called in both the monitor (reaping worker) and worker (SIGQUIT handler)
    def close # :nodoc:
      self.deadline = 0
      @monitor.close if @monitor
      @to_io.close if @to_io
    end

    def create_socketpair!
      @to_io, @monitor = Info.keep_ios(Pitchfork.socketpair)
    end

    def after_fork_in_child
      @monitor&.close
    end

    def to_log
      if mold?
        pid ? "mold gen=#{generation} pid=#{pid}" : "mold gen=#{generation}"
      else
        pid ? "worker=#{nr} gen=#{generation} pid=#{pid}" : "worker=#{nr} gen=#{generation}"
      end
    end

    private

    def init_state
      if nr
        @state_drop = SharedMemory.worker_state(@nr)
        self.deadline = 0
      else
        promoted!(nil)
      end
    end

    def pipe=(socket)
      raise ArgumentError, "pipe can't be nil" unless socket
      Info.keep_io(socket)
      @monitor = MessageSocket.new(socket)
    end

    def send_message_nonblock(message)
      success = false
      return false unless @monitor
      begin
        case @monitor.sendmsg_nonblock(message, exception: false)
        when :wait_writable
        else
          success = true
        end
      rescue Errno::EPIPE, Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::ENOTCONN
        # worker will be reaped soon
      end
      success
    end
  end

  class Service < Worker
    def initialize(pid: nil, generation: 0)
      super(nil, pid: pid, generation: generation)
    end

    def service?
      true
    end

    def register_to_monitor(control_socket)
      create_socketpair!
      message = Message::ServiceSpawned.new(@pid, generation, @monitor)
      control_socket.sendmsg(message)
      @monitor.close
    end

    def to_log
      pid ? "service gen=#{generation} pid=#{pid}" : "service gen=#{generation}"
    end

    private

    def init_state
      @state_drop = SharedMemory.service_state
      self.deadline = 0
    end
  end
end

# frozen_string_literal: true

module Pitchfork
  # :stopdoc:
  module SoftTimeout
    extend self

    CONDVAR = ConditionVariable.new
    QUEUE = Queue.new
    QUEUE_MUTEX = Mutex.new
    TIMEOUT_THREAD_MUTEX = Mutex.new
    @timeout_thread = nil
    private_constant :CONDVAR, :QUEUE, :QUEUE_MUTEX, :TIMEOUT_THREAD_MUTEX

    class Request
      attr_reader :deadline, :thread

      def initialize(thread, timeout, block)
        @thread = thread
        @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        @block = block

        @mutex = Mutex.new
        @done = false # protected by @mutex
      end

      def extend_deadline(timeout)
        @deadline += timeout
        QUEUE_MUTEX.synchronize do
          CONDVAR.signal
        end
        self
      end

      def done?
        @mutex.synchronize do
          @done
        end
      end

      def expired?(now)
        now >= @deadline
      end

      def interrupt
        @mutex.synchronize do
          unless @done
            begin
              @block.call(@thread)
            ensure
              @done = true
            end
          end
        end
      end

      def finished
        @mutex.synchronize do
          @done = true
        end
      end
    end

    def request(sec, callback)
      ensure_timeout_thread_created
      request = Request.new(Thread.current, sec, callback)
      QUEUE_MUTEX.synchronize do
        QUEUE << request
        CONDVAR.signal
      end
      request
    end

    private

    def create_timeout_thread
      watcher = Thread.new do
        requests = []
        while true
          until QUEUE.empty? and !requests.empty? # wait to have at least one request
            req = QUEUE.pop
            requests << req unless req.done?
          end
          closest_deadline = requests.min_by(&:deadline).deadline

          now = 0.0
          QUEUE_MUTEX.synchronize do
            while (now = Process.clock_gettime(Process::CLOCK_MONOTONIC)) < closest_deadline and QUEUE.empty?
              CONDVAR.wait(QUEUE_MUTEX, closest_deadline - now)
            end
          end

          requests.each do |req|
            req.interrupt if req.expired?(now)
          end
          requests.reject!(&:done?)
        end
      end
      watcher.name = "Pitchfork::Timeout"
      watcher
    end

    def ensure_timeout_thread_created
      unless @timeout_thread and @timeout_thread.alive?
        TIMEOUT_THREAD_MUTEX.synchronize do
          unless @timeout_thread and @timeout_thread.alive?
            @timeout_thread = create_timeout_thread
          end
        end
      end
    end
  end
end

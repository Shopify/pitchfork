# frozen_string_literal: true

require 'pitchfork/shared_memory'

module Pitchfork
  module Info
    @workers_count = 0
    @fork_safe = true
    @kept_ios = ObjectSpace::WeakMap.new

    class << self
      attr_accessor :workers_count

      def keep_io(io)
        @kept_ios[io] = io if io && !io.to_io.closed?
        io
      end

      def keep_ios(ios)
        ios.each { |io| keep_io(io) }
      end

      def close_all_fds!
        ignored_fds = [$stdin.to_i, $stdout.to_i, $stderr.to_i]
        @kept_ios.each_value do |io_like|
          if io = io_like&.to_io
            ignored_fds << io.to_i unless io.closed?
          end
        end

        all_fds = Dir.children("/dev/fd").map(&:to_i)
        all_fds -= ignored_fds

        all_fds.each do |fd|
          IO.for_fd(fd).close
        rescue ArgumentError
          # RubyVM internal file descriptor, leave it alone
        rescue Errno::EBADF
          # Likely a race condition
        end
      end

      def fork_safe?
        @fork_safe
      end

      def no_longer_fork_safe!
        @fork_safe = false
      end

      def live_workers_count
        now = Pitchfork.time_now(true)
        (0...workers_count).count do |nr|
          SharedMemory.worker_deadline(nr).value > now
        end
      end

      # Returns true if the server is shutting down.
      # This can be useful to implement health check endpoints, so they
      # can fail immediately after TERM/QUIT/INT was received by the master
      # process.
      # Otherwise they may succeed while Pitchfork is draining requests causing
      # more requests to be sent.
      def shutting_down?
        SharedMemory.shutting_down?
      end
    end
  end
end

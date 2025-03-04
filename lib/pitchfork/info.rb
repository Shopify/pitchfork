# frozen_string_literal: true

require 'pitchfork/shared_memory'

module Pitchfork
  module Info
    class WeakSet # :nodoc
      def initialize
        @map = ObjectSpace::WeakMap.new
      end

      if RUBY_VERSION < "2.7"
        def <<(object)
          @map[object] = object
        end
      else
        def <<(object)
          @map[object] = true
        end
      end

      def each(&block)
        @map.each_key(&block)
      end
    end

    if RUBY_VERSION < "3.2.3" && RUBY_ENGINE == "ruby"
      class << self
        def keep_io(io)
          io # noop
        end

        def keep_ios(ios)
          ios # noop
        end

        def close_all_ios!
          raise NoMethodError, <<~MSG
            Your Ruby version is subject to a bug that prevent `.close_all_ios!` from working.
            See: https://bugs.ruby-lang.org/issues/19531.

            Consider upgrading to Ruby 3.2.3+
          MSG
        end
      end
    else
      @kept_ios = WeakSet.new

      class << self
        def keep_io(io)
          raise ArgumentError, "#{io.inspect} doesn't respond to :to_io" unless io.respond_to?(:to_io)
          @kept_ios << io
          io
        end

        def keep_ios(ios)
          ios.each { |io| keep_io(io) }
        end

        def close_all_ios!
          ignored_ios = [$stdin, $stdout, $stderr, STDIN, STDOUT, STDERR].uniq.compact

          @kept_ios.each do |io_like|
            ignored_ios << (io_like.is_a?(IO) ? io_like : io_like.to_io)
          end

          ObjectSpace.each_object(IO) do |io|
            if io_open?(io) && io_autoclosed?(io) && !ignored_ios.include?(io)
              if io.is_a?(TCPSocket)
                # If we inherited a TCP Socket, calling #close directly could send FIN or RST.
                # So we first reopen /dev/null to avoid that.
                io.reopen(File::NULL)
              end
              begin
                io.close
              rescue Errno::EBADF
              end
            end
          end
        end
      end
    end

    @workers_count = 0
    @fork_safe = true

    class << self
      attr_accessor :workers_count

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
      # can fail immediately after TERM/QUIT/INT was received by the monitor
      # process.
      # Otherwise they may succeed while Pitchfork is draining requests causing
      # more requests to be sent.
      def shutting_down?
        SharedMemory.shutting_down?
      end

      private

      def io_open?(io)
        !io.closed?
      rescue IOError
        false
      end

      def io_autoclosed?(io)
        io.autoclose?
      rescue IOError
        false
      end
    end
  end
end

# frozen_string_literal: true

require 'pitchfork/shared_memory'

module Pitchfork
  module Info
    @workers_count = 0

    class << self
      attr_accessor :workers_count

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

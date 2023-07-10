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
    end
  end
end

# frozen_string_literal: true

module Pitchfork
  module ReforkCondition
    @backoff_delay = 10.0

    class << self
      attr_accessor :backoff_delay
    end

    class RequestsCount
      def initialize(request_counts)
        @limits = request_counts
        @backoff_until = nil
      end

      def met?(worker, logger)
        if limit = @limits.fetch(worker.generation) { @limits.last }
          if worker.requests_count >= limit
            return false if backoff?

            logger.info("#{worker.to_log} processed #{worker.requests_count} requests, triggering a refork")
            return true
          end
        end
        false
      end

      def backoff?
        return false if @backoff_until.nil?

        if @backoff_until > Pitchfork.time_now
          true
        else
          @backoff_until = nil
          false
        end
      end

      def backoff!(delay = ReforkCondition.backoff_delay)
        @backoff_until = Pitchfork.time_now + delay
      end
    end
  end
end

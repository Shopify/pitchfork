# frozen_string_literal: true

module Pitchfork
  module ReforkCondition
    class RequestsCount
      def initialize(request_counts)
        @limits = request_counts
        @backoff_until = nil
      end

      def met?(worker, logger)
        if limit = @limits.fetch(worker.generation) { @limits.last }
          if worker.requests_count >= limit
            return false if backoff?

            logger.info("worker=#{worker.nr} pid=#{worker.pid} processed #{worker.requests_count} requests, triggering a refork")
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

      def backoff!(delay = 10.0)
        @backoff_until = Pitchfork.time_now + delay
      end
    end
  end
end

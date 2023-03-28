# frozen_string_literal: true

module Pitchfork
  module ReforkCondition
    class RequestsCount
      def initialize(request_counts)
        @limits = request_counts
      end

      def met?(worker, logger)
        if limit = @limits[worker.generation]
          if worker.requests_count >= limit
            logger.info("worker=#{worker.nr} pid=#{worker.pid} processed #{worker.requests_count} requests, triggering a refork")
            return true
          end
        end
        false
      end
    end
  end
end

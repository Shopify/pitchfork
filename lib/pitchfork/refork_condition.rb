# frozen_string_literal: true

module Pitchfork
  module ReforkCondition
    class RequestsCount
      def initialize(request_counts)
        @limits = request_counts
      end

      def met?(children, logger)
        if limit = @limits[children.last_generation]
          if worker = children.fresh_workers.find { |w| w.requests_count >= limit }
            logger.info("worker=#{worker.nr} pid=#{worker.pid} processed #{worker.requests_count} requests, triggering a refork")
            return true
          end
        end
        false
      end
    end
  end
end

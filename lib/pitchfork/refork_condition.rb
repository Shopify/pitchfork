# frozen_string_literal: true

module Pitchfork
  module ReforkCondition
    class MaxMemory
      def initialize(max_memory)
        @cutoff = max_memory / 1000.0 # convert to kB
      end

      def met?(children, logger)
        children.total_pss > @cutoff
      end
    end
  end
end

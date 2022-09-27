# frozen_string_literal: true

module Pitchfork
  module MoldSelector
    class Base
      def initialize(children)
        @children = children
      end
    end

    def select(_logger)
      raise NotImplementedError, "Must implement #select"
    end

    class LeastSharedMemory < Base
      def select(logger)
        workers = @children.fresh_workers
        if workers.empty?
          logger.info("No current generation workers yet")
          return
        end
        candidate = workers.shift
        candidate_meminfo = MemInfo.new(candidate.pid)

        workers.each do |worker|
          worker_meminfo = MemInfo.new(worker.pid)
          if worker_meminfo.shared_memory < candidate_meminfo.shared_memory
            # We suppose that a worker with a lower amount of shared memory
            # has warmed up more caches & such, hence is closer to stabilize
            # making it a better candidate.
            candidate, candidate_meminfo = worker, worker_meminfo
          end
        end
        parent_meminfo = MemInfo.new(@children.mold&.pid || Process.pid)
        cow_efficiency = candidate_meminfo.cow_efficiency(parent_meminfo)
        logger.info("worker=#{candidate.nr} pid=#{candidate.pid} selected as new mold shared_memory_kb=#{candidate_meminfo.shared_memory} cow=#{cow_efficiency.round(1)}%")
        candidate
      end
    end
  end
end

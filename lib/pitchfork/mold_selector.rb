# frozen_string_literal: true

module Pitchfork
  module MoldSelector
    class LeastSharedMemory
      def call(server)
        workers = server.children.fresh_workers
        if workers.empty?
          server.logger.info("No current generation workers yet")
          return
        end
        candidate = workers.shift

        workers.each do |worker|
          if worker.meminfo.shared_memory < candidate.meminfo.shared_memory
            # We suppose that a worker with a lower amount of shared memory
            # has warmed up more caches & such, hence is closer to stabilize
            # making it a better candidate.
            candidate = worker
          end
        end
        parent_meminfo = server.children.mold&.meminfo || MemInfo.new(Process.pid)
        cow_efficiency = candidate.meminfo.cow_efficiency(parent_meminfo)
        server.logger.info("worker=#{candidate.nr} pid=#{candidate.pid} selected as new mold shared_memory_kb=#{candidate.meminfo.shared_memory} cow=#{cow_efficiency.round(1)}%")
        candidate
      end
    end
  end
end

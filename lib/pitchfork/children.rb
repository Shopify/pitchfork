# -*- encoding: binary -*-
require 'child_subreaper'

module Pitchfork
  # This class keep tracks of the state of all the master children.
  class Children
    attr_reader :mold
    attr_accessor :last_generation

    def initialize
      @last_generation = 0
      @children = {} # All children, including molds, indexed by PID.
      @workers = {} # Workers indexed by their `nr`.
      @molds = {} # Molds, index by PID.
      @mold = nil # The latest mold, if any.
      @pending_workers = {} # Pending workers indexed by their `nr`.
      @pending_molds = {} # Worker promoted to mold, not yet acknowledged
    end

    def refresh
      @workers.each_value(&:refresh)
      @molds.each_value(&:refresh)
    end

    def register(child)
      # Children always start as workers, never molds, so we know they have a `#nr`.
      @pending_workers[child.nr] = @workers[child.nr] = child
    end

    def register_mold(mold)
      @pending_molds[mold.pid] = mold
      @children[mold.pid] = mold
      @mold = mold
    end

    def fetch(pid)
      @children.fetch(pid)
    end

    def update(message)
      child = @children[message.pid] || (message.nr && @workers[message.nr])
      old_nr = child.nr

      child.update(message)

      if child.mold?
        @workers.delete(old_nr)
        @pending_molds.delete(child.pid)
        @molds[child.pid] = child
        @mold = child
      end
      if child.pid
        @children[child.pid] = child
        @pending_workers.delete(child.nr)
      end
      child
    end

    def nr_alive?(nr)
      @workers.key?(nr)
    end

    def reap(pid)
      if child = @children.delete(pid)
        @pending_workers.delete(child.nr)
        @pending_molds.delete(child.pid)
        @molds.delete(child.pid)
        @workers.delete(child.nr)
        if @mold == child
          @mold = nil
        end
      end
      child
    end

    def promote(worker)
      @pending_molds[worker.pid] = worker
      worker.promote(self.last_generation += 1)
    end

    def pending_workers?
      !(@pending_workers.empty? && @pending_molds.empty?)
    end

    def pending_promotion?
      !@pending_molds.empty?
    end

    def molds
      @molds.values
    end

    def each(&block)
      @children.each_value(&block)
    end

    def each_worker(&block)
      @workers.each_value(&block)
    end

    def workers
      @workers.values
    end

    def fresh_workers
      if @mold
        workers.select { |w| w.generation >= @mold.generation }
      else
        workers
      end
    end

    def workers_count
      @workers.size
    end

    def total_pss
      total_pss = MemInfo.new(Process.pid).pss
      @children.each do |_, worker|
        total_pss += worker.meminfo.pss if worker.meminfo
      end
      total_pss
    end
  end
end

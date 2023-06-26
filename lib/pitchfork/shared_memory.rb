# frozen_string_literal: true

require 'raindrops'

module Pitchfork
  module SharedMemory
    extend self

    PER_DROP = Raindrops::PAGE_SIZE / Raindrops::SIZE
    CURRENT_GENERATION_OFFSET = 0
    MOLD_TICK_OFFSET = 1
    WORKER_TICK_OFFSET = 2

    DROPS = [Raindrops.new(PER_DROP)]

    def current_generation
      DROPS[0][CURRENT_GENERATION_OFFSET]
    end

    def current_generation=(value)
      DROPS[0][CURRENT_GENERATION_OFFSET] = value
    end

    class Field
      def initialize(offset)
        @drop = DROPS.fetch(offset / PER_DROP)
        @offset = offset % PER_DROP
      end

      def value
        @drop[@offset]
      end

      def value=(value)
        @drop[@offset] = value
      end
    end

    def mold_tick
      self[MOLD_TICK_OFFSET]
    end

    def worker_tick(worker_nr)
      self[WORKER_TICK_OFFSET + worker_nr]
    end

    def [](offset)
      Field.new(offset)
    end

    # Since workers are created from another process, we have to
    # pre-allocate the drops so they are shared between everyone.
    #
    # However this doesn't account for TTIN signals that increase the
    # number of workers, but we should probably remove that feature too.
    def preallocate_drops(workers_count)
      0.upto(((WORKER_TICK_OFFSET + workers_count) / PER_DROP.to_f).ceil) do |i|
        DROPS[i] ||= Raindrops.new(PER_DROP)
      end
    end
  end
end
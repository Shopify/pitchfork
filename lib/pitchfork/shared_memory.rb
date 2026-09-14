# frozen_string_literal: true

module Pitchfork
  module SharedMemory
    extend self

    CURRENT_GENERATION_OFFSET = 0
    SHUTDOWN_OFFSET = 1
    MOLD_TICK_OFFSET = 2
    MOLD_PROMOTION_TICK_OFFSET = 3
    SERVICE_TICK_OFFSET = 4
    WORKER_TICK_OFFSET = 5

    PAGES = []

    def close_on_exec=(close_on_exec)
      PAGES.each { |p| p.close_on_exec = close_on_exec }
    end

    READY_FLAG = 1 << 0
    BUSY_FLAG = 1 << 1
    DEADLINE_SHIFT = 2

    FLAGS_MASK = 0x3

    def current_generation
      PAGES[0][CURRENT_GENERATION_OFFSET]
    end

    def current_generation=(value)
      PAGES[0][CURRENT_GENERATION_OFFSET] = value
    end

    def shutting_down!
      PAGES[0][SHUTDOWN_OFFSET] = 1
    end

    def shutting_down?
      PAGES[0][SHUTDOWN_OFFSET] > 0
    end

    class Field
      def initialize(offset)
        @drop = PAGES.fetch(offset / MemoryPage::SLOTS)
        @offset = offset % MemoryPage::SLOTS
      end

      def value
        @drop[@offset]
      end

      def value=(value)
        @drop[@offset] = value
      end
    end

    class WorkerState
      def initialize(field)
        @field = field
      end

      def ready?
        (@field.value & READY_FLAG) == READY_FLAG
      end

      def ready=(bool)
        if bool
          @field.value |= READY_FLAG
        else
          @field.value &= ~READY_FLAG
        end
      end

      def busy?
        (@field.value & BUSY_FLAG) == BUSY_FLAG
      end

      def busy=(bool)
        if bool
          @field.value |= BUSY_FLAG
        else
          @field.value &= ~BUSY_FLAG
        end
      end

      def deadline=(deadline)
        # Shift the value up and preserve the current ready bit.
        @field.value = (deadline << DEADLINE_SHIFT) | (@field.value & FLAGS_MASK)
      end

      def deadline
        @field.value >> DEADLINE_SHIFT
      end

      def reset!
        @field.value = 0
      end
    end

    def mold_state
      WorkerState.new(self[MOLD_TICK_OFFSET])
    end

    def mold_promotion_state
      WorkerState.new(self[MOLD_PROMOTION_TICK_OFFSET])
    end

    def service_state
      WorkerState.new(self[SERVICE_TICK_OFFSET])
    end

    def worker_state(worker_nr)
      WorkerState.new(self[WORKER_TICK_OFFSET + worker_nr])
    end

    def [](offset)
      Field.new(offset)
    end

    # Since workers are created from another process, we have to
    # pre-allocate the drops so they are shared between everyone.
    #
    # However this doesn't account for TTIN signals that increase the
    # number of workers, but we should probably remove that feature too.
    def preallocate_pages(workers_count)
      ((WORKER_TICK_OFFSET + workers_count) / MemoryPage::SLOTS.to_f).ceil.times do |i|
        PAGES[i] ||= MemoryPage.new(MemoryPage::SLOTS)
      end
    end
  end
end

# frozen_string_literal: true

module Pitchfork

  class Listeners
    class Group
      def initialize(listeners, queues_per_worker:)
        @listeners = listeners
        @queues_per_worker = queues_per_worker
      end

      def each(&block)
        @listeners.each(&block)
      end

      def for_worker(nr)
        index = nr % @listeners.size

        listeners = @listeners.slice(index..-1) + @listeners.slice(0...index)
        listeners.take(@queues_per_worker)
      end
    end

    include Enumerable

    def initialize(listeners = [])
      @listeners = listeners
    end

    def for_worker(nr)
      ios = []
      @listeners.each do |listener|
        if listener.is_a?(Group)
          ios += listener.for_worker(nr)
        else
          ios << listener
        end
      end
      ios
    end

    def each(&block)
      @listeners.each do |listener|
        if listener.is_a?(Group)
          listener.each(&block)
        else
          yield listener
        end
      end
      self
    end

    def clear
      @listeners.clear
    end

    def <<(listener)
      @listeners << listener
    end

    def empty?
      @listeners.empty?
    end
  end
end

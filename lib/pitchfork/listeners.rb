# frozen_string_literal: true

module Pitchfork

  class Listeners
    class << self
      def load(data)
        data.map { |l| load_io(l) }
      end

      def dump_io(io)
        {
          class: io.class,
          fd: io.fileno,
        }
      end

      def load_io(data)
        data[:class].for_fd(data[:fd])
      end
    end

    class Group
      class << self
        def load(data)
          allocate.init_with(data)
        end
      end

      def initialize(listeners, queues_per_worker:)
        @listeners = listeners
        @queues_per_worker = queues_per_worker
      end

      def init_with(data)
        @listeners = data.fetch(:listerners).map { |l| Listeners.load_io(l) }
        @queues_per_worker = data.fetch(:queues_per_worker)
      end

      def dump
        raise "hot restart with listen queues isn't supported (yet?)"
      end

      def close_on_exec=(close_on_exec)
        @listeners.each { |l| l.close_on_exec = close_on_exec }
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

    def close_on_exec=(close_on_exec)
      @listeners.each { |l| l.close_on_exec = close_on_exec }
    end

    def init_with(listeners)
      @listeners = listeners.map do |data|
        if data[:class] == Group
          Group.load(data)
        else
          Listeners.load_io(data)
        end
      end
    end

    def dump
      map do |listener|
        if listener.is_a?(Group)
          raise "hot restart with listen queues isn't supported (yet?)"
        else
          Listeners.dump_io(listener)
        end
      end
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

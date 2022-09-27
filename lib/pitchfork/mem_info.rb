# frozen_string_literal: true

module Pitchfork
  class MemInfo
    attr_reader :rss, :pss, :shared_memory

    def initialize(pid)
      @pid = pid
      update
    end

    def children
      File.read("/proc/#{@pid}/task/#{@pid}/children").split.map { |pid| MemInfo.new(pid) }
    end

    def cow_efficiency(parent_meminfo)
      shared_memory.to_f / parent_meminfo.rss * 100.0
    end

    def update
      info = parse(File.read("/proc/#{@pid}/smaps_rollup"))
      @pss = info.fetch(:Pss)
      @rss = info.fetch(:Rss)
      @shared_memory = info.fetch(:Shared_Clean) + info.fetch(:Shared_Dirty)
      self
    end

    private

    def parse(rollup)
      fields = {}
      rollup.each_line do |line|
        if (matchdata = line.match(/(?<field>\w+)\:\s+(?<size>\d+) kB$/))
          fields[matchdata[:field].to_sym] = matchdata[:size].to_i
        end
      end
      fields
    end
  end
end

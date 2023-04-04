require 'test_helper'

module Pitchfork
  class TestReforkCondition < Pitchfork::Test
    def setup
      @logger = Logger.new(nil)
      @worker = Worker.new(0, pid: 42)
    end

    def test_requests_count_repeat
      @condition = ReforkCondition::RequestsCount.new([10, 50])

      refute @condition.met?(@worker, @logger)
      @worker.increment_requests_count(11)
      assert @condition.met?(@worker, @logger)

      @worker.promote!
      @worker.reset

      refute @condition.met?(@worker, @logger)
      @worker.increment_requests_count(11)
      refute @condition.met?(@worker, @logger)
      @worker.increment_requests_count(40)
      assert @condition.met?(@worker, @logger)

      @worker.promote!
      @worker.reset

      @worker.increment_requests_count(49)
      refute @condition.met?(@worker, @logger)
      @worker.increment_requests_count(1)
      assert @condition.met?(@worker, @logger)
    end

    def test_requests_count_stop
      @condition = ReforkCondition::RequestsCount.new([10, nil])

      refute @condition.met?(@worker, @logger)
      @worker.increment_requests_count(11)
      assert @condition.met?(@worker, @logger)

      @worker.promote!
      @worker.reset

      refute @condition.met?(@worker, @logger)
      @worker.increment_requests_count(50)
      refute @condition.met?(@worker, @logger)
    end
  end
end

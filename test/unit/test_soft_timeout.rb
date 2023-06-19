require 'test_helper'

module Pitchfork
  class TestSoftTimeout < Pitchfork::Test
    def test_soft_timeout
      called = []
      timeout = SoftTimeout.request(0.5, -> (thread) { called << thread })
      sleep 1
      assert_equal [Thread.current], called
      assert_predicate timeout, :done?
    ensure
      timeout&.finished
    end

    def test_extend_deadline
      called = []
      timeout = SoftTimeout.request(0.5, -> (thread) { called << thread })
      timeout.extend_deadline(2)
      sleep 1
      assert_equal [], called
      refute_predicate timeout, :done?
    ensure
      timeout&.finished
    end

    def test_cancel
      called = []
      timeout = SoftTimeout.request(0.5, -> (thread) { called << thread })
      timeout.finished
      sleep 1
      assert_equal [], called
      assert_predicate timeout, :done?
    end
  end
end

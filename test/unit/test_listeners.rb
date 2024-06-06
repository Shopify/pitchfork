# frozen_string_literal: true
require 'test_helper'

class TestListerners < Pitchfork::Test
  def test_for_worker_distribution
    group = Pitchfork::Listeners::Group.new([1, 2], queues_per_worker: 2)
    assert_equal [1, 2], group.for_worker(0)
    assert_equal [2, 1], group.for_worker(1)

    group = Pitchfork::Listeners::Group.new([1, 2], queues_per_worker: 1)
    assert_equal [1], group.for_worker(0)
    assert_equal [2], group.for_worker(1)
  end
end

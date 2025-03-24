# frozen_string_literal: true
require 'test_helper'

class TestWorker < Pitchfork::Test
  def test_create_many_workers
    Pitchfork::SharedMemory.preallocate_pages(1024)

    now = Time.now.to_i
    (0...1024).each do |i|
      worker = Pitchfork::Worker.new(i)
      assert worker.respond_to?(:deadline)
      assert_equal 0, worker.deadline
      assert_equal(now, worker.deadline = now)
      assert_equal now, worker.deadline
      assert_equal(0, worker.deadline = 0)
      assert_equal 0, worker.deadline
    end
  end

  def test_shared_process
    worker = Pitchfork::Worker.new(0)
    _, status = Process.waitpid2(fork { worker.deadline += 1; exit!(0) })
    assert status.success?, status.inspect
    assert_equal 1, worker.deadline

    _, status = Process.waitpid2(fork { worker.deadline += 1; exit!(0) })
    assert status.success?, status.inspect
    assert_equal 2, worker.deadline
  end

  def test_state
    worker = Pitchfork::Worker.new(0)
    now = Time.now.to_i
    worker.deadline = now
    worker.ready = true

    assert_equal now, worker.deadline
    assert worker.ready?

    worker.ready = false
    assert_equal now, worker.deadline
    refute worker.ready?

    worker.ready = true
    now = now + 1
    worker.deadline = now

    assert_equal now, worker.deadline
    assert worker.ready?, "ready state was not preserved"

    worker.deadline = 0
    assert_equal 0, worker.deadline
    refute worker.ready?, "ready state failed to reset"
  end
end

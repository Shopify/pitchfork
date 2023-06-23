require 'test_helper'

class TestWorker < Pitchfork::Test
  def test_create_many_workers
    Pitchfork::SharedMemory.preallocate_drops(1024)

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
end

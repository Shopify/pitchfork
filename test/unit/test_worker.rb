# frozen_string_literal: true
require 'test_helper'

module Pitchfork
  class TestWorker < Test
    def test_create_many_workers
      SharedMemory.preallocate_pages(1024)

      now = Time.now.to_i
      (0...1024).each do |i|
        worker = Worker.new(i)
        assert worker.respond_to?(:deadline)
        assert_equal 0, worker.deadline
        assert_equal(now, worker.deadline = now)
        assert_equal now, worker.deadline
        assert_equal(0, worker.deadline = 0)
        assert_equal 0, worker.deadline
      end
    end

    def test_shared_process
      worker = Worker.new(0)
      _, status = Process.waitpid2(fork { worker.deadline += 1; exit!(0) })
      assert status.success?, status.inspect
      assert_equal 1, worker.deadline

      _, status = Process.waitpid2(fork { worker.deadline += 1; exit!(0) })
      assert status.success?, status.inspect
      assert_equal 2, worker.deadline
    end

    def test_state
      worker = Worker.new(0)
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

    def test_dump_load
      worker = Worker.new(2, pid: 1234, generation: 1)
      worker.create_socketpair!
      expected = {
        exiting: false,
        generation: 1,
        version: 0,
        mold: false,
        mold_ready: false,
        service: false,
        nr: 2,
        pid: 1234,
        requests_count: 0,
        monitor_fd: worker.monitor.fileno,
      }
      state = worker.dump
      assert_equal(expected, state)

      cloned_worker = Worker.load(state)
      assert_equal worker.monitor.class, cloned_worker.monitor.class
      assert_equal worker.monitor.fileno, cloned_worker.monitor.fileno
      assert_equal worker.requests_count, cloned_worker.requests_count
      assert_equal worker.pid, cloned_worker.pid
    end
  end
end

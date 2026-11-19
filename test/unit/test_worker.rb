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

    def test_new_worker_keeps_shared_state_until_reset
      [[0, false], [nil, true]].each do |nr, service|
        existing = Worker.new(nr, service: service)
        existing.deadline = 123
        existing.ready = true
        existing.busy = true

        worker = Worker.new(nr, service: service)
        assert_equal 123, worker.deadline
        assert worker.ready?
        assert worker.busy?

        worker.reset_state!
        assert_equal 0, existing.deadline
        refute existing.ready?
        refute existing.busy?
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
      worker.busy = true

      assert_equal now, worker.deadline
      assert worker.ready?
      assert worker.busy?

      worker.ready = false
      assert_equal now, worker.deadline
      refute worker.ready?
      assert worker.busy?

      worker.ready = true
      now = now + 1
      worker.deadline = now

      assert_equal now, worker.deadline
      assert worker.ready?, "ready state was not preserved"

      worker.busy = false
      assert_equal now, worker.deadline
      assert worker.ready?
      refute worker.busy?

      worker.close
      assert worker.ready?, "ready state was reset on close"
      assert_equal now, worker.deadline
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

      # A restart replaces the process image before reloading the descriptor.
      worker.monitor.to_io.autoclose = false
      cloned_worker = Worker.load(state)
      assert_equal worker.monitor.class, cloned_worker.monitor.class
      assert_equal worker.monitor.fileno, cloned_worker.monitor.fileno
      assert_equal worker.requests_count, cloned_worker.requests_count
      assert_equal worker.pid, cloned_worker.pid
    end
  end
end

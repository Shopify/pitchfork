# frozen_string_literal: true

require 'test_helper'

module Pitchfork
  class TestInfo < Test
    def test_close_all_ios_except_marked_ones
      if RUBY_VERSION < '3.2.3'
        assert_raises NoMethodError do
          Info.close_all_ios!
        end
      else
        r, w = IO.pipe

        Info.keep_io(w)

        pid = Process.fork do
          Info.close_all_ios!

          w.write(Marshal.dump([
            $stdin.closed?,
            $stdout.closed?,
            $stderr.closed?,
            r.closed?,
            w.closed?
          ]))
          Process.exit!(0)
        end

        _, status = Process.wait2(pid)
        assert_predicate status, :success?

        info = Marshal.load(r)

        assert_equal([
          false, # $stdin
          false, # $stdout
          false, # $stderr
          true, # r
          false, # w
        ], info)
      end
    end

    def test_idle_workers_count
      Info.workers_count = 10
      now = Pitchfork.time_now(true)
      Info.workers_count.times do |i|
        state = SharedMemory.worker_state(i)
        state.ready = true
        state.busy = false
        state.deadline = now + 1_000
      end

      assert_equal 10, Info.workers_count
      assert_equal 10, Info.idle_workers_count

      SharedMemory.worker_state(2).busy = true
      assert_equal 9, Info.idle_workers_count

      SharedMemory.worker_state(3).ready = false
      assert_equal 8, Info.idle_workers_count

      SharedMemory.worker_state(3).busy = true
      assert_equal 8, Info.idle_workers_count

      SharedMemory.worker_state(4).deadline = now - 5
      assert_equal 7, Info.idle_workers_count
    end
  end
end

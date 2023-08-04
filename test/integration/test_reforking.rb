require 'integration_test_helper'

class ReforkingTest < Pitchfork::IntegrationTest
  if Pitchfork::REFORKING_AVAILABLE
    def test_reforking
      addr, port = unused_port

      pid = spawn_server(app: File.join(ROOT, "test/integration/env.ru"), config: <<~CONFIG)
        listen "#{addr}:#{port}"
        worker_processes 2
        refork_after [5, 5]
      CONFIG

      assert_healthy("http://#{addr}:#{port}")
      assert_stderr "worker=0 gen=0 ready"
      assert_stderr "worker=1 gen=0 ready"

      9.times do
        assert_equal true, healthy?("http://#{addr}:#{port}")
      end

      assert_stderr "Refork condition met, promoting ourselves", timeout: 3
      assert_stderr "Terminating old mold pid="
      assert_stderr "worker=0 gen=1 ready"
      assert_stderr "worker=1 gen=1 ready"

      File.truncate("stderr.log", 0)

      9.times do
        assert_equal true, healthy?("http://#{addr}:#{port}")
      end

      assert_stderr "worker=0 gen=2 ready", timeout: 3
      assert_stderr "worker=1 gen=2 ready"

      assert_clean_shutdown(pid)
    end

    def test_reforking_broken_after_mold_fork_hook
      addr, port = unused_port

      pid = spawn_server(app: File.join(ROOT, "test/integration/env.ru"), config: <<~CONFIG)
        listen "#{addr}:#{port}"
        worker_processes 2
        refork_after [5, 5]
        after_mold_fork do |_server, mold|
          raise "Oops" if mold.generation > 0
        end
      CONFIG

      assert_healthy("http://#{addr}:#{port}")
      assert_stderr "worker=0 gen=0 ready"
      assert_stderr "worker=1 gen=0 ready"

      9.times do
        assert_equal true, healthy?("http://#{addr}:#{port}")
      end

      assert_stderr "Refork condition met, promoting ourselves", timeout: 3
      assert_stderr(/mold pid=\d+ gen=1 reaped/)

      assert_equal true, healthy?("http://#{addr}:#{port}")

      assert_clean_shutdown(pid)
    end

    def test_fork_unsafe
      addr, port = unused_port

      pid = spawn_server(app: File.join(ROOT, "test/integration/fork_unsafe.ru"), config: <<~CONFIG)
        listen "#{addr}:#{port}"
        worker_processes 2
        refork_after [5, 5]
      CONFIG

      assert_healthy("http://#{addr}:#{port}")
      assert_stderr "worker=0 gen=0 ready"
      assert_stderr "worker=1 gen=0 ready"

      20.times do
        assert_equal true, healthy?("http://#{addr}:#{port}")
      end

      refute_match("Refork condition met, promoting ourselves", read_stderr)

      assert_clean_shutdown(pid)
    end

    def test_reforking_on_USR2
      addr, port = unused_port

      pid = spawn_server(app: File.join(ROOT, "test/integration/env.ru"), config: <<~CONFIG)
        listen "#{addr}:#{port}"
        worker_processes 2
      CONFIG

      assert_healthy("http://#{addr}:#{port}")
      assert_stderr "worker=0 gen=0 ready"
      assert_stderr "worker=1 gen=0 ready"

      Process.kill(:USR2, pid)

      assert_stderr "Terminating old mold pid="
      assert_stderr "worker=0 gen=1 ready"
      assert_stderr "worker=1 gen=1 ready"

      assert_healthy("http://#{addr}:#{port}")
      assert_clean_shutdown(pid)
    end

    def test_reforking_on_USR2_fork_unsafe_worker
      addr, port = unused_port

      pid = spawn_server(app: File.join(ROOT, "test/integration/env.ru"), config: <<~CONFIG)
        listen "#{addr}:#{port}"
        worker_processes 1

        after_worker_fork do |_server, worker|
          if worker.nr == 0
            Pitchfork::Info.no_longer_fork_safe!
          end
        end
      CONFIG

      assert_healthy("http://#{addr}:#{port}")
      assert_stderr "worker=0 gen=0 ready"

      Process.kill(:USR2, pid)

      assert_stderr "is no longer fork safe, can't refork"

      assert_healthy("http://#{addr}:#{port}")
      assert_clean_shutdown(pid)
    end

    def test_slow_worker_rollout
      addr, port = unused_port

      pid = spawn_server(app: File.join(ROOT, "test/integration/env.ru"), config: <<~CONFIG)
        listen "#{addr}:#{port}"
        worker_processes 5
        after_worker_fork do |_server, worker|
          Kernel.at_exit do
            sleep 0.1
          end
        end
      CONFIG

      assert_healthy("http://#{addr}:#{port}")
      assert_stderr "worker=0 gen=0 ready"
      assert_stderr "worker=4 gen=0 ready"

      Process.kill(:USR2, pid)

      assert_stderr "worker=0 gen=1 ready"
      assert_stderr "worker=1 gen=1 ready"
      assert_stderr "worker=2 gen=1 ready"
      assert_stderr "worker=3 gen=1 ready"
      assert_stderr "worker=4 gen=1 ready"

      assert_clean_shutdown(pid)

      log_lines = read_stderr.lines.drop_while { |l| !l.match?(/Terminating old mold/) }
      log_lines = log_lines.take_while { |l| !l.match?(/QUIT received/) }

      events = log_lines.map do |line|
        case line
        when /Sent SIGTERM to worker/
          :term
        when /registered/
          :registered
        end
      end.compact
      assert_equal([:term, :registered] * 5, events)
    end
  end
end

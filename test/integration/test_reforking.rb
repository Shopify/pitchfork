# frozen_string_literal: true
require 'integration_test_helper'

class ReforkingTest < Pitchfork::IntegrationTest
  if Pitchfork::REFORKING_AVAILABLE
    def test_reforking
      addr, port = unused_port

      pid = spawn_server(app: File.join(ROOT, "test/integration/env.ru"), config: <<~CONFIG)
        listen "#{addr}:#{port}"
        worker_processes 2
        refork_after [5, 5]
        refork_max_unavailable 1
      CONFIG

      assert_healthy("http://#{addr}:#{port}")
      assert_stderr(/worker=0 gen=0 pid=\d+ ready/)
      assert_stderr(/worker=1 gen=0 pid=\d+ ready/)

      9.times do
        assert_equal true, healthy?("http://#{addr}:#{port}")
      end

      assert_stderr "refork condition met, promoting ourselves", timeout: 3
      assert_stderr "Terminating old mold gen=0 pid="
      assert_stderr(/worker=0 gen=1 pid=\d+ ready/)
      assert_stderr(/worker=1 gen=1 pid=\d+ ready/)

      File.truncate("stderr.log", 0)

      9.times do
        assert_equal true, healthy?("http://#{addr}:#{port}")
      end

      assert_stderr(/worker=0 gen=2 pid=\d+ ready/, timeout: 3)
      assert_stderr(/worker=1 gen=2 pid=\d+ ready/)

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
      assert_stderr(/worker=0 gen=0 pid=\d+ ready/)
      assert_stderr(/worker=1 gen=0 pid=\d+ ready/)

      9.times do
        assert_equal true, healthy?("http://#{addr}:#{port}")
      end

      assert_stderr "refork condition met, promoting ourselves", timeout: 3
      assert_stderr(/mold gen=1 pid=\d+ reaped/)

      assert_equal true, healthy?("http://#{addr}:#{port}")

      assert_clean_shutdown(pid)
    end

    def test_broken_mold
      addr, port = unused_port

      pid = spawn_server(app: File.join(ROOT, "test/integration/env.ru"), config: <<~CONFIG)
        listen "#{addr}:#{port}"
        worker_processes 2
        spawn_timeout 2
        refork_after [5, 5]
        after_mold_fork do |_server, mold|
          if mold.generation > 0
            def Process.fork
              # simulate some issue causing children to fail.
              # Typically some native background thread holding a lock
              # right when we fork.
              Process.spawn("false")
            end
          end
        end
      CONFIG

      assert_healthy("http://#{addr}:#{port}")
      assert_stderr(/worker=0 gen=0 pid=\d+ ready/)
      assert_stderr(/worker=1 gen=0 pid=\d+ ready/, timeout: 5)

      9.times do
        assert_equal true, healthy?("http://#{addr}:#{port}")
      end

      assert_stderr "refork condition met, promoting ourselves", timeout: 3

      assert_stderr "failed to spawn a worker, retrying"
      assert_stderr "failed to spawn a worker twice in a row - corrupted mold process?"
      assert_stderr "No mold alive, shutting down"

      assert_exited(pid, 1, timeout: 5)
    end

    def test_exiting_mold
      addr, port = unused_port

      pid = spawn_server(app: File.join(ROOT, "test/integration/env.ru"), config: <<~CONFIG)
        Pitchfork::ReforkCondition.backoff_delay = 0.0

        listen "#{addr}:#{port}"
        worker_processes 2
        spawn_timeout 2
        refork_after [5, 5]
        after_mold_fork do |_server, mold|
          if mold.generation > 0
            if File.exist?("crashed-once.txt")
              $stderr.puts "[mold success]"
            else
              File.write("crashed-once.txt", "1")
              $stderr.puts "[mold crashing]"
              exit 1
            end
          end
        end
      CONFIG

      assert_healthy("http://#{addr}:#{port}")
      assert_stderr(/worker=0 gen=0 pid=\d+ ready/)
      assert_stderr(/worker=1 gen=0 pid=\d+ ready/, timeout: 5)

      7.times do
        assert_equal true, healthy?("http://#{addr}:#{port}")
      end

      assert_stderr(/mold gen=1 pid=\d+ spawned/)
      assert_stderr("[mold crashing]")
      assert_stderr(/mold gen=1 pid=\d+ reaped/)

      10.times do
        assert_equal true, healthy?("http://#{addr}:#{port}")
      end

      assert_stderr(/worker=0 gen=1 pid=\d+ ready/, timeout: 15)
      assert_stderr(/worker=1 gen=1 pid=\d+ ready/)

      assert_clean_shutdown(pid)
    end

    def test_stuck_mold
      addr, port = unused_port

      pid = spawn_server(app: File.join(ROOT, "test/integration/env.ru"), config: <<~CONFIG)
        Pitchfork::ReforkCondition.backoff_delay = 1.0

        listen "#{addr}:#{port}"
        worker_processes 2
        spawn_timeout 1
        refork_after [5, 5]
        after_mold_fork do |_server, mold|
          if mold.generation > 0
            if File.exist?("stuck-once.txt")
              $stderr.puts "[mold success]"
            else
              File.write("stuck-once.txt", "1")
              $stderr.puts "[mold locking-up]"
              sleep 5
            end
          end
        end
      CONFIG

      assert_healthy("http://#{addr}:#{port}")
      assert_stderr(/worker=0 gen=0 pid=\d+ ready/)
      assert_stderr(/worker=1 gen=0 pid=\d+ ready/, timeout: 5)

      7.times do
        assert_equal true, healthy?("http://#{addr}:#{port}")
      end

      assert_stderr(/mold gen=1 pid=\d+ spawned/)
      assert_stderr("[mold locking-up]")
      assert_stderr(/mold gen=1 pid=\d+ reaped/, timeout: 10)

      10.times do
        assert_equal true, healthy?("http://#{addr}:#{port}")
      end

      assert_stderr(/worker=0 gen=1 pid=\d+ ready/, timeout: 5)
      assert_stderr(/worker=1 gen=1 pid=\d+ ready/)

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
      assert_stderr(/worker=0 gen=0 pid=\d+ ready/)
      assert_stderr(/worker=1 gen=0 pid=\d+ ready/)

      20.times do
        assert_equal true, healthy?("http://#{addr}:#{port}")
      end

      refute_match("refork condition met, promoting ourselves", read_stderr)

      assert_clean_shutdown(pid)
    end

    def test_reforking_on_USR2
      addr, port = unused_port

      pid = spawn_server(app: File.join(ROOT, "test/integration/env.ru"), config: <<~CONFIG)
        listen "#{addr}:#{port}"
        worker_processes 2
      CONFIG

      assert_healthy("http://#{addr}:#{port}")
      assert_stderr(/worker=0 gen=0 pid=\d+ ready/)
      assert_stderr(/worker=1 gen=0 pid=\d+ ready/)

      Process.kill(:USR2, pid)

      assert_stderr "Terminating old mold gen=0 pid="
      assert_stderr(/worker=0 gen=1 pid=\d+ ready/)
      assert_stderr(/worker=1 gen=1 pid=\d+ ready/)

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
      assert_stderr(/worker=0 gen=0 pid=\d+ ready/)

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
      assert_stderr(/worker=0 gen=0 pid=\d+ ready/)
      assert_stderr(/worker=4 gen=0 pid=\d+ ready/)

      Process.kill(:USR2, pid)

      assert_stderr(/worker=0 gen=1 pid=\d+ ready/)
      assert_stderr(/worker=1 gen=1 pid=\d+ ready/)
      assert_stderr(/worker=2 gen=1 pid=\d+ ready/)
      assert_stderr(/worker=3 gen=1 pid=\d+ ready/)
      assert_stderr(/worker=4 gen=1 pid=\d+ ready/)

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

    def test_signal_during_refork
      addr, port = unused_port

      flag_path = "/tmp/signal-sent-#{rand}.txt"

      # Ref: https://github.com/Shopify/pitchfork/issues/160
      # Simulate a TERM being received while initializing a mold
      pid = spawn_server(app: File.join(ROOT, "test/integration/env.ru"), config: <<~CONFIG)
        listen "#{addr}:#{port}"
        worker_processes 1
        refork_after [1, nil]

        Pitchfork::ReforkCondition.backoff_delay = 0.0

        after_mold_fork do |server, mold|
          if mold.generation == 1
            if !File.exist?("#{flag_path}")
              File.write("#{flag_path}", "1")
              server.logger.info("SELF KILL")
              Process.kill(:TERM, Process.pid)
            else
              server.logger.info("SUCCESS")
            end
          end
        end
      CONFIG

      2.times do
        assert_healthy("http://#{addr}:#{port}")
      end

      assert_stderr(/mold gen=1 pid=\d+ reaped/)

      2.times do
        assert_healthy("http://#{addr}:#{port}")
      end

      assert_stderr(/SUCCESS/)

      assert_clean_shutdown(pid)
    end
  end
end

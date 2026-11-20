# frozen_string_literal: true
require 'integration_test_helper'

class TestBoot < Pitchfork::IntegrationTest
  ROOT = File.expand_path('../../', __dir__)
  BIN = File.join(ROOT, 'exe/pitchfork')
  APP = File.join(ROOT, "examples/hello.ru")

  def setup
    super

    @_old_pwd = Dir.pwd
    @_pids = []
    @pwd = Dir.mktmpdir('pitchfork')
    Dir.chdir(@pwd)
  end

  def teardown
    pids = @_pids.select do |pid|
      Process.kill('INT', pid)
      true
    rescue Errno::ESRCH
      false
    end

    pids.reject! do |pid|
      Process.wait(pid, Process::WNOHANG)
    rescue Errno::ESRCH, Errno::ECHILD
      true
    end

    unless pids.empty?
      sleep 0.2
    end

    pids.reject! do |pid|
      Process.wait(pid, Process::WNOHANG)
    rescue Errno::ESRCH, Errno::ECHILD
      true
    end

    pids.reject! do |pid|
      Process.kill('KILL', pid)
      false
    rescue Errno::ESRCH
      true
    end

    pids.each do |pid|
      Process.wait(pid)
    end

    Dir.chdir(@_old_pwd)
    if __result__.failure?
      $stderr.puts("Working directory left at: #{@pwd}")
    else
      FileUtils.rm_rf(@pwd)
    end
  end

  def test_boot_minimal
    addr, port = unused_port

    pid = spawn_server(app: APP, config: <<~RUBY)
      listen "#{addr}:#{port}"
      worker_processes 2
      refork_after [50, 100, 1000]
    RUBY

    assert_healthy("http://#{addr}:#{port}")
    assert_clean_shutdown(pid)
  end

  def test_ready_callback_before_child_exit
    [:worker, :service].each do |child_type|
      addr, port = unused_port
      message_type = child_type == :worker ? "WorkerReady" : "ServiceReady"

      pid = spawn_server(app: APP, config: <<~RUBY)
        listen "#{addr}:#{port}"
        worker_processes 1
        before_service_worker_ready { |_server, _service| } if #{child_type == :service}

        module ExitAfterReadyMessage
          def monitor_sleep(seconds)
            super
            message = @sig_queue.last
            if message.is_a?(Pitchfork::Message::#{message_type}) && !@killed_ready_child
              @killed_ready_child = true
              Process.kill(:KILL, message.pid)
              deadline = Pitchfork.time_now + 3
              until `ps -o stat= -p \#{message.pid}`.lstrip.start_with?("Z")
                raise "child did not exit" if Pitchfork.time_now >= deadline
                sleep 0.01
              end
            end
          end
        end
        Pitchfork::HttpServer.prepend(ExitAfterReadyMessage)

        after_child_ready do |_server, child|
          if child.worker? || child.service?
            type = child.service? ? "service" : "worker"
            $stderr.puts "[ready callback] \#{type} pid=\#{child.pid}"
          end
        end
      RUBY

      assert_stderr(/\[ready callback\] #{child_type} pid=\d+/, timeout: 5)
      child_pid = read_stderr.match(/\[ready callback\] #{child_type} pid=(\d+)/)[1]
      exit_pattern = /(?:worker=0|service) gen=0\.0 pid=#{child_pid} reaped/
      assert_stderr(exit_pattern, timeout: 5)
      assert_healthy("http://#{addr}:#{port}")
      assert_clean_shutdown(pid)

      output = read_stderr
      ready_message = "[ready callback] #{child_type} pid=#{child_pid}"
      assert_equal 1, output.scan(ready_message).size
      assert_operator output.index(ready_message), :<, output.index(exit_pattern)
    end
  end

  def test_ready_callback_before_immediate_shutdown
    [:before_shutdown, :during_shutdown].each do |exit_time|
      addr, port = unused_port

      pid = spawn_server(app: APP, config: <<~RUBY)
        listen "#{addr}:#{port}"
        worker_processes 1

        module ShutdownAfterReadyMessage
          def wait_for_zombie(pid)
            deadline = Pitchfork.time_now + 3
            until `ps -o stat= -p \#{pid}`.lstrip.start_with?("Z")
              raise "worker did not exit" if Pitchfork.time_now >= deadline
              sleep 0.01
            end
          end

          def monitor_sleep(seconds)
            super
            message = @sig_queue.last
            if message.is_a?(Pitchfork::Message::WorkerReady) && !@stopped_ready_worker
              @stopped_ready_worker = message.pid
              if #{exit_time == :before_shutdown}
                Process.kill(:KILL, message.pid)
                wait_for_zombie(message.pid)
              end
              @sig_queue.unshift(:INT)
              @sig_queue << :USR2 if #{exit_time == :during_shutdown}
            end
          end

          def monitor_loop(sleep = true)
            if #{exit_time == :during_shutdown} && @stopped_ready_worker && !@respawn && !@waited_for_shutdown
              @waited_for_shutdown = true
              wait_for_zombie(@stopped_ready_worker)
            end
            super
          end
        end
        Pitchfork::HttpServer.prepend(ShutdownAfterReadyMessage)

        after_child_ready do |_server, child|
          $stderr.puts "[ready callback] pid=\#{child.pid}" if child.worker?
        end
      RUBY

      assert_stderr(/\[ready callback\] pid=\d+/, timeout: 5)
      child_pid = read_stderr.match(/\[ready callback\] pid=(\d+)/)[1]
      exit_pattern = /worker=0 gen=0\.0 pid=#{child_pid} reaped/
      assert_stderr(exit_pattern, timeout: 5)
      assert_exited(pid, 0)
      output = read_stderr
      ready_message = "[ready callback] pid=#{child_pid}"
      assert_equal 1, output.scan(ready_message).size
      assert_operator output.index(ready_message), :<, output.index(exit_pattern)
    end
  end

  def test_boot_broken_after_mold_fork
    addr, port = unused_port

    pid = spawn_server(app: APP, config: <<~RUBY)
      listen "#{addr}:#{port}"
      worker_processes 2
      refork_after [50, 100, 1000]
      after_mold_fork do |_server, _mold|
        raise "Oops"
      end
    RUBY

    assert_exited(pid, 1)
  end

  def test_boot_worker_stuck_in_spawn
    addr, port = unused_port

    pid = spawn_server(app: APP, config: <<~RUBY)
      listen "#{addr}:#{port}"
      worker_processes 2
      refork_after [50, 100, 1000]
      spawn_timeout 2
      after_worker_fork do |_server, worker|
        if worker.nr == 1
          sleep 20 # simulate a stuck worker
        end
      end
    RUBY


    assert_healthy("http://#{addr}:#{port}")

    assert_stderr(/worker=0 gen=0.0 pid=\d+ ready/)
    assert_stderr(/worker=1 gen=0.0 pid=\d+ spawned/)
    assert_stderr(/worker=1 gen=0.0 pid=\d+ timed out, killing/, timeout: 4)

    assert_clean_shutdown(pid)
  end

  def test_max_consecutive_spawn_timeout
    addr, port = unused_port

    pid = spawn_server(app: APP, config: <<~RUBY)
      listen "#{addr}:#{port}"
      worker_processes 3
      max_consecutive_spawn_errors 2
      spawn_timeout 1
      after_worker_fork do |_server, worker|
        sleep 20 # simulate a stuck worker
      end
    RUBY

    assert_stderr(/consecutive failures to spawn children, aborting/, timeout: 4)
    assert_exited(pid, 1)
  end

  def test_max_consecutive_spawn_timeout_counts_each_timeout_once
    addr, port = unused_port

    pid = spawn_server(app: APP, config: <<~RUBY)
      listen "#{addr}:#{port}"
      worker_processes 1
      max_consecutive_spawn_errors 1
      spawn_timeout 1
      after_worker_fork do |_server, worker|
        sleep 20
      end
    RUBY

    assert_stderr(/consecutive failures to spawn children, aborting/, timeout: 6)
    assert_exited(pid, 1)
    before_abort = read_stderr.split("consecutive failures to spawn children, aborting").first
    assert_equal 2, before_abort.scan(/worker=0 gen=0.0 pid=\d+ timed out, killing/).size
  end

  def test_max_consecutive_spawn_errors
    addr, port = unused_port

    pid = spawn_server(app: APP, config: <<~RUBY)
      listen "#{addr}:#{port}"
      worker_processes 3
      max_consecutive_spawn_errors 2
      spawn_timeout 1
      after_worker_fork do |_server, worker|
        raise "Ooops"
      end
    RUBY

    assert_stderr(/consecutive failures to spawn children, aborting/, timeout: 4)
    assert_exited(pid, 1)
  end

  def test_max_consecutive_spawn_errors_ignores_ready_workers
    addr, port = unused_port

    pid = spawn_server(app: APP, config: <<~RUBY)
      listen "#{addr}:#{port}"
      worker_processes 4
      max_consecutive_spawn_errors 1
    RUBY

    assert_healthy("http://#{addr}:#{port}")
    assert_stderr(/worker=3 gen=0.0 pid=\d+ ready/)

    Process.kill(:TTOU, pid)
    assert_stderr(/worker=3 gen=0.0 pid=\d+ reaped/)
    Process.kill(:TTOU, pid)
    assert_stderr(/worker=2 gen=0.0 pid=\d+ reaped/)

    assert_healthy("http://#{addr}:#{port}")
    refute_stderr(/consecutive failures to spawn children/)
    assert_clean_shutdown(pid)
  end

  test "workers and mold exit on monitor crash", isolated: true do
    skip("Missing CHILD_SUBREAPER") unless Pitchfork::CHILD_SUBREAPER_AVAILABLE

    Pitchfork.enable_child_subreaper

    addr, port = unused_port

    pid = spawn_server(app: APP, config: <<~RUBY)
      listen "#{addr}:#{port}"
      worker_processes 2
      timeout 3
      refork_after [50, 100, 1000]
    RUBY

    assert_healthy("http://#{addr}:#{port}")
    assert_stderr(/worker=0 gen=0.0 pid=\d+ ready/)
    assert_stderr(/worker=1 gen=0.0 pid=\d+ ready/)

    Process.kill(:KILL, pid)
    Process.waitpid(pid)

    assert_stderr(/worker=0 gen=0.0 pid=(\d+) exiting/, timeout: 5)
    assert_stderr(/worker=1 gen=0.0 pid=(\d+) exiting/, timeout: 5)

    assert_raises Errno::ESRCH, Errno::ECHILD do
      25.times do
        Process.wait(-1, Process::WNOHANG)
        sleep 0.2
      end
    end
  end

  test "abandoned worker coming up late" do
    addr, port = unused_port

    pid = spawn_server(app: APP, config: <<~RUBY)
      listen "#{addr}:#{port}"
      worker_processes 1
      spawn_timeout 1

      module LogReadyMessage
        def notify_ready(control_socket)
          super
          $stderr.puts "[ready message] pid=\#{pid}"
        end
      end
      Pitchfork::Worker.prepend(LogReadyMessage)

      module SlowSpawnWorkerPatch
        def spawn_worker(worker)
          @_spawn_worker_count ||= 0
          @_spawn_worker_count += 1
          if @_spawn_worker_count == 1
            File.write("first-spawn-pending", "")
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 8
            until File.exist?("release-first-spawn") || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
              sleep 0.01
            end
          end
          super
        end

        def init_worker_process(worker)
          if @_spawn_worker_count == 1
            sleep 3
            logger.info("getting ready")
          end
          super
        end
      end

      after_mold_fork do |server, _mold|
        server.extend(SlowSpawnWorkerPatch)
      end

      after_monitor_ready do |server|
        def server.murder_lazy_workers
          if children.workers_count > 0 && !@checked_first_spawn
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
            until File.exist?("first-spawn-pending") || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
              sleep 0.01
            end
            @checked_first_spawn = true
          end
          super
        end
      end

      after_child_ready do |_server, child|
        $stderr.puts "[ready callback] pid=\#{child.pid}" if child.worker?
      end
    RUBY

    assert_stderr(/worker=0 gen=0.0 timed out during spawn, abandoning/, timeout: 5)
    File.write("release-first-spawn", "")
    assert_stderr(/worker=0 gen=0.0 pid=(\d+) spawned but slot is taken/, timeout: 5)

    abandoned_worker_pid = read_stderr.match(/worker=0 gen=0.0 pid=(\d+) spawned but slot is taken/)[1]
    assert_stderr("[ready message] pid=#{abandoned_worker_pid}", timeout: 5)
    assert_stderr(/reaped unknown subprocess .* pid #{abandoned_worker_pid} exit 0/)
    refute_stderr(/monitor loop error/)

    assert_clean_shutdown(pid)
    refute_stderr("[ready callback] pid=#{abandoned_worker_pid}")
  end
end

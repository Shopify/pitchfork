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

  def test_mold_ready_callback_without_reforking
    addr, port = unused_port
    pid = spawn_server(app: APP, config: <<~RUBY)
      Pitchfork.send(:remove_const, :REFORKING_AVAILABLE)
      Pitchfork.const_set(:REFORKING_AVAILABLE, false)
      listen "#{addr}:#{port}"
      worker_processes 1
      after_child_ready do |_server, child|
        if child.mold?
          $stderr.puts "[mold] ready=\#{child.ready?} promotion_ready=\#{Pitchfork::SharedMemory.mold_promotion_state.ready?}"
        end
      end
    RUBY

    assert_stderr("[mold] ready=true promotion_ready=false")
    assert_healthy("http://#{addr}:#{port}")
    assert_clean_shutdown(pid)
  end

  def test_initial_and_promoted_molds_are_ready_in_callback
    skip("Missing refork support") unless Pitchfork::REFORKING_AVAILABLE

    addr, port = unused_port
    pid = spawn_server(app: APP, config: <<~RUBY)
      listen "#{addr}:#{port}"
      worker_processes 1
      refork_after [2, 2]

      module PauseAfterMoldReady
        def finish_promotion(control_socket)
          Pitchfork::SharedMemory.mold_state.ready = false
          super
          deadline = Pitchfork.time_now + 5
          until File.exist?("mold-ready-\#{generation}")
            raise "monitor did not observe mold readiness" if Pitchfork.time_now >= deadline
            sleep 0.01
          end
        end
      end
      Pitchfork::Worker.prepend(PauseAfterMoldReady)

      after_child_ready do |_server, child|
        if child.mold?
          $stderr.puts "[mold \#{child.generation}] ready=\#{child.ready?}"
          File.write("mold-ready-\#{child.generation}", "")
        end
      end
    RUBY

    assert_stderr("[mold 0] ready=true")
    5.times { assert_healthy("http://#{addr}:#{port}") }
    assert_stderr("[mold 1] ready=true", timeout: 5)
    assert_clean_shutdown(pid)
  end

  def test_legacy_mold_updates_readiness_after_callback
    skip("Missing refork support") unless Pitchfork::REFORKING_AVAILABLE

    addr, port = unused_port
    pid = spawn_server(app: APP, config: <<~RUBY)
      listen "#{addr}:#{port}"
      worker_processes 1

      module LegacyMoldReady
        def finish_promotion(control_socket)
          Pitchfork::SharedMemory.mold_state.ready = false
          control_socket.sendmsg(Pitchfork::Message::MoldReady.new(pid))
          deadline = Pitchfork.time_now + 5
          until File.exist?("legacy-mold-observed")
            raise "monitor did not observe mold readiness" if Pitchfork.time_now >= deadline
            sleep 0.01
          end
          @state_drop = Pitchfork::SharedMemory.mold_state
          self.ready = true
        end
      end
      Pitchfork::Worker.prepend(LegacyMoldReady)

      after_child_ready do |_server, child|
        if child.mold?
          $stderr.puts "[legacy mold] ready=\#{child.ready?}"
          File.write("legacy-mold-observed", "")
        end
      end
    RUBY

    assert_stderr("[legacy mold] ready=false")
    assert_healthy("http://#{addr}:#{port}")
    assert_clean_shutdown(pid)
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
    RUBY

    assert_stderr(/worker=0 gen=0.0 timed out during spawn, abandoning/, timeout: 5)
    File.write("release-first-spawn", "")
    assert_stderr(/worker=0 gen=0.0 pid=(\d+) spawned but slot is taken/, timeout: 5)

    abandoned_worker_pid = read_stderr.match(/worker=0 gen=0.0 pid=(\d+) spawned but slot is taken/)[1]
    assert_stderr(/reaped unknown subprocess .* pid #{abandoned_worker_pid} exit 0/)
    refute_stderr(/monitor loop error/)

    assert_clean_shutdown(pid)
  end
end

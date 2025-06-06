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

    assert_stderr(/worker=0 gen=0 pid=\d+ ready/)
    assert_stderr(/worker=1 gen=0 pid=\d+ registered/)
    assert_stderr(/worker=1 gen=0 pid=\d+ timed out, killing/, timeout: 4)

    assert_clean_shutdown(pid)
  end

  def test_max_consecutive_spawn_timeout
    addr, port = unused_port

    pid = spawn_server(app: APP, config: <<~RUBY)
      listen "#{addr}:#{port}"
      worker_processes 3
      max_consecutive_spawn_errors 4
      spawn_timeout 1
      after_worker_fork do |_server, worker|
        sleep 20 # simulate a stuck worker
      end
    RUBY

    assert_stderr(/consecutive failures to spawn children, aborting/, timeout: 4)
    assert_exited(pid, 1)
  end

  def test_max_consecutive_spawn_errors
    addr, port = unused_port

    pid = spawn_server(app: APP, config: <<~RUBY)
      listen "#{addr}:#{port}"
      worker_processes 3
      max_consecutive_spawn_errors 4
      spawn_timeout 1
      after_worker_fork do |_server, worker|
        raise "Ooops"
      end
    RUBY

    assert_stderr(/consecutive failures to spawn children, aborting/, timeout: 4)
    assert_exited(pid, 1)
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
    assert_stderr(/worker=0 gen=0 pid=\d+ ready/)
    assert_stderr(/worker=1 gen=0 pid=\d+ ready/)

    Process.kill(:KILL, pid)
    Process.waitpid(pid)

    assert_stderr(/worker=0 gen=0 pid=(\d+) exiting/, timeout: 5)
    assert_stderr(/worker=1 gen=0 pid=(\d+) exiting/)

    assert_raises Errno::ESRCH, Errno::ECHILD do
      25.times do
        Process.wait(-1, Process::WNOHANG)
        sleep 0.2
      end
    end
  end
end

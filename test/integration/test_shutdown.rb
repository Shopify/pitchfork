# frozen_string_literal: true
require 'integration_test_helper'

class TestShutdown < Pitchfork::IntegrationTest
  SLOW_APP = <<~'RUBY'
    run lambda { |env|
      if (seconds = env["QUERY_STRING"].to_f) > 0
        $stderr.puts "request started pid=#{Process.pid}"
        sleep seconds
      end
      [200, {}, ["done\n"]]
    }
  RUBY

  test "TTIN during a graceful shutdown doesn't spawn workers" do
    addr, port = unused_port
    pid = spawn_server(app: write_app, config: <<~RUBY)
      listen "#{addr}:#{port}"
      worker_processes 1
    RUBY
    start_slow_request(addr, port, 3)

    Process.kill(:QUIT, pid)
    assert_stderr("QUIT received, starting graceful shutdown")
    Process.kill(:TTIN, pid)

    assert_exited(pid, 0, timeout: 6)
    refute_stderr(/worker=1|No mold alive/)
  end

  test "graceful shutdown doesn't busy-loop the monitor" do
    addr, port = unused_port
    pid = spawn_server(app: write_app, config: <<~RUBY)
      listen "#{addr}:#{port}"
      worker_processes 1
    RUBY
    start_slow_request(addr, port, 4)

    cpu_before = cpu_time(pid)
    Process.kill(:QUIT, pid)
    sleep 3
    assert_operator cpu_time(pid) - cpu_before, :<, 1.5

    assert_exited(pid, 0, timeout: 4)
  end

  test "repeated QUIT still waits for workers to exit" do
    addr, port = unused_port
    pid = spawn_server(app: write_app, config: <<~RUBY)
      listen "#{addr}:#{port}"
      worker_processes 1
      timeout 3
    RUBY
    worker_pid = start_slow_request(addr, port, 30)

    Process.kill(:QUIT, pid)
    assert_stderr("QUIT received, starting graceful shutdown")
    Process.kill(:QUIT, pid)

    assert_exited(pid, 0, timeout: 8)
    assert_raises(Errno::ESRCH) { Process.kill(0, worker_pid) }
  ensure
    Process.kill(:KILL, worker_pid) rescue nil
  end

  test "repeated QUIT waits for a pending worker" do
    addr, port = unused_port
    pid = spawn_pending_worker(addr, port, spawn_timeout: 10)
    assert_healthy("http://#{addr}:#{port}")
    Process.kill(:TTIN, pid)
    assert_stderr(/pending worker pid=\d+/, timeout: 5)
    worker_pid = Integer(read_stderr[/pending worker pid=(\d+)/, 1])

    Process.kill(:QUIT, pid)
    assert_stderr("QUIT received, starting graceful shutdown")
    Process.kill(:QUIT, pid)
    assert_stderr(/QUIT received, starting graceful shutdown.*QUIT received, starting graceful shutdown/m, timeout: 5)
    sleep 0.2
    assert_nil Process.waitpid(pid, Process::WNOHANG)

    File.write("continue-worker", "")
    assert_exited(pid, 0, timeout: 5)
    assert_raises(Errno::ESRCH) { Process.kill(0, worker_pid) }
  ensure
    Process.kill(:KILL, worker_pid) rescue nil
  end

  test "a worker that exceeds its spawn timeout exits after shutdown" do
    addr, port = unused_port
    pid = spawn_pending_worker(addr, port, spawn_timeout: 1)
    assert_healthy("http://#{addr}:#{port}")
    Process.kill(:TTIN, pid)
    assert_stderr(/pending worker pid=\d+/, timeout: 5)
    worker_pid = Integer(read_stderr[/pending worker pid=(\d+)/, 1])

    Process.kill(:QUIT, pid)
    assert_stderr("QUIT received, starting graceful shutdown")
    Process.kill(:QUIT, pid)
    assert_exited(pid, 0, timeout: 6)

    File.write("continue-worker", "")
    assert_stderr("pending worker continuing", timeout: 5)
    assert_process_exits(worker_pid)
    worker_pid = nil
  ensure
    Process.kill(:KILL, worker_pid) rescue nil
  end

  test "a pending service worker exits after shutdown" do
    addr, port = unused_port
    pid = spawn_server(app: write_app, config: <<~RUBY)
      listen "#{addr}:#{port}"
      worker_processes 1

      module SlowPendingService
        def init_service_process(service)
          $stderr.puts "pending service pid=\#{Process.pid}"
          sleep 0.01 until File.exist?("continue-service")
          $stderr.puts "pending service continuing"
          super
        end
      end

      after_mold_fork { |server, _mold| server.extend(SlowPendingService) }
      before_service_worker_ready { |_server, _service| }
    RUBY
    assert_healthy("http://#{addr}:#{port}")
    assert_stderr(/pending service pid=\d+/, timeout: 5)
    service_pid = Integer(read_stderr[/pending service pid=(\d+)/, 1])

    Process.kill(:QUIT, pid)
    assert_exited(pid, 0, timeout: 5)
    File.write("continue-service", "")
    assert_stderr("pending service continuing", timeout: 5)
    assert_process_exits(service_pid)
    service_pid = nil
  ensure
    Process.kill(:KILL, service_pid) rescue nil
  end

  test "USR1 during a graceful shutdown does not restart the monitor" do
    addr, port = unused_port
    pid = spawn_server(app: write_app, config: <<~RUBY)
      listen "#{addr}:#{port}"
      worker_processes 1
    RUBY
    start_slow_request(addr, port, 3)

    Process.kill(:QUIT, pid)
    assert_stderr("QUIT received, starting graceful shutdown")
    Process.kill(:QUIT, pid)
    assert_stderr(/QUIT received, starting graceful shutdown.*QUIT received, starting graceful shutdown/m, timeout: 5)
    Process.kill(:USR1, pid)

    assert_stderr("Can't trigger a restart as the server is shutting down", timeout: 3)
    assert_exited(pid, 0, timeout: 6)
  end

  test "INT during a graceful shutdown kills workers immediately" do
    addr, port = unused_port
    pid = spawn_server(app: write_app, config: <<~RUBY)
      listen "#{addr}:#{port}"
      worker_processes 1
    RUBY
    worker_pid = start_slow_request(addr, port, 30)

    Process.kill(:QUIT, pid)
    assert_stderr("QUIT received, starting graceful shutdown")
    Process.kill(:INT, pid)

    assert_exited(pid, 0, timeout: 2)
    assert_raises(Errno::ESRCH) { Process.kill(0, worker_pid) }
  ensure
    Process.kill(:KILL, worker_pid) rescue nil
  end

  private

  def assert_process_exits(pid)
    50.times do
      Process.kill(0, pid)
      sleep 0.1
    rescue Errno::ESRCH
      return
    end
    flunk "process pid=#{pid} did not exit"
  end

  def spawn_pending_worker(addr, port, spawn_timeout:)
    spawn_server(app: write_app, config: <<~RUBY)
      listen "#{addr}:#{port}"
      worker_processes 1
      spawn_timeout #{spawn_timeout}

      module SlowPendingWorker
        def init_worker_process(worker)
          if worker.nr == 1
            $stderr.puts "pending worker pid=\#{Process.pid}"
            sleep 0.01 until File.exist?("continue-worker")
            $stderr.puts "pending worker continuing"
          end
          super
        end
      end

      after_mold_fork { |server, _mold| server.extend(SlowPendingWorker) }
    RUBY
  end

  def write_app
    File.write("slow.ru", SLOW_APP)
    File.join(@pwd, "slow.ru")
  end

  def start_slow_request(addr, port, seconds)
    assert_healthy("http://#{addr}:#{port}")
    Thread.new { http_get("http://#{addr}:#{port}/?#{seconds}", timeout: seconds + 5) rescue nil }
    assert_stderr(/request started pid=\d+/, timeout: 5)
    Integer(read_stderr[/request started pid=(\d+)/, 1])
  end

  def cpu_time(pid)
    `ps -o time= -p #{pid}`.split(":").map(&:to_f).reverse.each_with_index.sum { |n, i| n * 60**i }
  end
end

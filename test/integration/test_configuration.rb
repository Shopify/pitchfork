# frozen_string_literal: true
require 'integration_test_helper'

class ConfigurationTest < Pitchfork::IntegrationTest
  def test_after_request_complete
    addr, port = unused_port

    pid = spawn_server(app: File.join(ROOT, "test/integration/env.ru"), config: <<~CONFIG)
      listen "#{addr}:#{port}"
      worker_processes 1

      after_request_complete do |server, worker, env|
        $stderr.puts "[after_request_complete] worker_requests_count=\#{worker.requests_count} path=\#{env['PATH_INFO']}"
      end

      before_worker_exit do |server, worker|
        $stderr.puts "[before_worker_exit]"
      end
    CONFIG

    assert_healthy("http://#{addr}:#{port}")
    assert_stderr("[after_request_complete] worker_requests_count=1 path=/")
    assert_healthy("http://#{addr}:#{port}")

    assert_clean_shutdown(pid)
  end

  def test_before_fork
    addr, port = unused_port

    pid = spawn_server(app: File.join(ROOT, "test/integration/env.ru"), config: <<~CONFIG)
      listen "#{addr}:#{port}"
      worker_processes 1

      before_fork do |server|
        $stderr.puts "[before_fork]"
      end
    CONFIG

    assert_healthy("http://#{addr}:#{port}")
    assert_stderr("[before_fork]")
    assert_clean_shutdown(pid)
  end
  def test_before_worker_exit
    addr, port = unused_port

    pid = spawn_server(app: File.join(ROOT, "test/integration/env.ru"), config: <<~CONFIG)
      listen "#{addr}:#{port}"
      worker_processes 1

      before_worker_exit do |server, worker|
        $stderr.puts "[before_worker_exit]"
      end
    CONFIG

    assert_healthy("http://#{addr}:#{port}")
    assert_clean_shutdown(pid)
    assert_stderr("[before_worker_exit]")
  end

  def test_soft_timeout
    addr, port = unused_port

    pid = spawn_server(app: File.join(ROOT, "test/integration/sleep.ru"), config: <<~CONFIG)
      listen "#{addr}:#{port}"
      worker_processes 1
      timeout 3, cleanup: 10

      after_worker_timeout do |server, worker, timeout_info|
        $stderr.puts "[after_worker_timeout]"
      end

      before_worker_exit do |server, worker|
        $stderr.puts "[before_worker_exit]"
      end
    CONFIG

    assert_healthy("http://#{addr}:#{port}/")

    assert_equal false, healthy?("http://#{addr}:#{port}/?10")
    assert_stderr("timed out, exiting")
    assert_stderr("[after_worker_timeout]")
    assert_stderr("[before_worker_exit]")

    assert_clean_shutdown(pid)
  end

  def test_soft_timeout_failure
    addr, port = unused_port

    pid = spawn_server(app: File.join(ROOT, "test/integration/sleep.ru"), config: <<~CONFIG)
      listen "#{addr}:#{port}"
      worker_processes 1
      timeout 3, cleanup: 10

      after_worker_timeout do |server, worker, timeout_info|
        raise "[after_worker_timeout] Ooops"
      end
    CONFIG

    assert_healthy("http://#{addr}:#{port}/")

    assert_equal false, healthy?("http://#{addr}:#{port}/?10")
    assert_stderr("timed out, exiting")
    assert_stderr("[after_worker_timeout] Ooops")

    assert_clean_shutdown(pid)
  end

  def test_hard_timeout
    addr, port = unused_port

    pid = spawn_server(app: File.join(ROOT, "test/integration/sleep.ru"), config: <<~CONFIG)
      listen "#{addr}:#{port}"
      worker_processes 1
      timeout 3, cleanup: 2

      after_worker_timeout do |server, worker, timeout_info|
        $stderr.puts "[after_worker_timeout]"
        sleep 60
      end

      after_worker_hard_timeout do |server, worker|
        $stderr.puts "[after_worker_hard_timeout] pid=\#{worker.pid}"
      end
    CONFIG

    assert_healthy("http://#{addr}:#{port}")

    assert_equal false, healthy?("http://#{addr}:#{port}/?10")
    assert_stderr("timed out, exiting")
    assert_stderr("[after_worker_timeout]")
    assert_stderr("timed out, killing")
    assert_stderr("[after_worker_hard_timeout]")

    assert_clean_shutdown(pid)
  end

  def test_listen_queues
    addr, port = unused_port

    pid = spawn_server(app: File.join(ROOT, "test/integration/env.ru"), config: <<~CONFIG)
      listen "#{addr}:#{port}", queues: 2, queues_per_worker: 1
      worker_processes 2
    CONFIG

    assert_stderr(/listening on addr=.* fd=\d+$/)
    assert_stderr(/listening on addr=.* fd=\d+ \(SO_REUSEPORT\)$/)

    4.times do
      assert_healthy("http://#{addr}:#{port}")
    end

    assert_clean_shutdown(pid)
  end

  def test_listener_names
    addr, port = unused_port

    pid = spawn_server(app: File.join(ROOT, "test/integration/apps/listener_names.ru"), config: <<~CONFIG)
      listen "#{addr}:#{port}"
      worker_processes 1
    CONFIG

    assert_healthy("http://#{addr}:#{port}")
    listener_names = Net::HTTP.get(URI("http://#{addr}:#{port}"))
    
    assert_equal(["#{addr}:#{port}"].inspect, listener_names)
    assert_clean_shutdown(pid)
  end

  def test_modify_internals
    addr, port = unused_port

    pid = spawn_server(app: File.join(ROOT, "test/integration/env.ru"), config: <<~CONFIG)
      listen "#{addr}:#{port}", queues: 1
      worker_processes 1

      HttpParser::DEFAULTS["rack.url_scheme"] = "https"
      Configurator::DEFAULTS[:logger].progname = "[FOO]"
    CONFIG

    assert_healthy("http://#{addr}:#{port}")

    env = Net::HTTP.get(URI("http://#{addr}:#{port}/"))
    assert_match({"rack.url_scheme"=>"https"}.inspect[1..-2], env)
    assert_stderr(/\[FOO\]/)

    assert_clean_shutdown(pid)
  end

  def test_setpgid_true
    addr, port = unused_port

    pid = spawn_server(app: File.join(ROOT, "test/integration/pid.ru"), config: <<~CONFIG)
      listen "#{addr}:#{port}"
      worker_processes 1

      setpgid true
    CONFIG

    assert_healthy("http://#{addr}:#{port}")

    worker_pid = Net::HTTP.get(URI("http://#{addr}:#{port}")).strip.to_i

    pgid_pid = Process.getpgid(pid)
    pgid_worker = Process.getpgid(worker_pid)

    refute_equal(pgid_pid, pgid_worker)
    assert_clean_shutdown(pid)
  end

  def test_setpgid_false
    addr, port = unused_port

    pid = spawn_server(app: File.join(ROOT, "test/integration/pid.ru"), config: <<~CONFIG)
      listen "#{addr}:#{port}"
      worker_processes 1

      setpgid false
    CONFIG

    assert_healthy("http://#{addr}:#{port}")

    worker_pid = Net::HTTP.get(URI("http://#{addr}:#{port}")).strip.to_i

    pgid_pid = Process.getpgid(pid)
    pgid_worker = Process.getpgid(worker_pid)

    assert_equal(pgid_pid, pgid_worker)
    assert_clean_shutdown(pid)
  end

  def test_at_exit_handlers
    addr, port = unused_port

    pid = spawn_server(app: File.join(ROOT, "test/integration/pid.ru"), config: <<~CONFIG)
      listen "#{addr}:#{port}"

      at_exit { \$stderr.puts("\#{Process.pid} BOTH") }
      END { \$stderr.puts("\#{Process.pid} END BOTH") }
      after_worker_fork do |_,_|
        at_exit { \$stderr.puts("\#{Process.pid} WORKER ONLY") }
        END { \$stderr.puts("\#{Process.pid} END WORKER ONLY") }
      end
    CONFIG

    assert_healthy("http://#{addr}:#{port}")

    worker_pid = Net::HTTP.get(URI("http://#{addr}:#{port}")).strip

    assert_clean_shutdown(pid)
    
    assert_stderr("#{worker_pid} BOTH")
    assert_stderr("#{pid} BOTH")
    assert_stderr("#{worker_pid} END BOTH")
    assert_stderr("#{pid} END BOTH")
    assert_stderr("#{worker_pid} WORKER ONLY")
    assert_stderr("#{worker_pid} END WORKER ONLY")
  end
end

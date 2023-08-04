require 'integration_test_helper'

class ConfigurationTest < Pitchfork::IntegrationTest
  def test_after_request_complete
    addr, port = unused_port

    pid = spawn_server(app: File.join(ROOT, "test/integration/env.ru"), config: <<~CONFIG)
      listen "#{addr}:#{port}"
      worker_processes 1

      request_count = 0
      after_request_complete do |server, worker, env|
        request_count += 1
        $stderr.puts "[after_request_complete] request_count=\#{request_count} path=\#{env['PATH_INFO']}"
      end

      before_worker_exit do |server, worker|
        $stderr.puts "[before_worker_exit]"
      end
    CONFIG

    assert_healthy("http://#{addr}:#{port}")
    assert_stderr("[after_request_complete] request_count=1 path=/")
    assert_healthy("http://#{addr}:#{port}")

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
end

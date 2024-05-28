# frozen_string_literal: true
require 'integration_test_helper'

class ServiceWorkerTest < Pitchfork::IntegrationTest
  def test_start_and_exit
    addr, port = unused_port

    pid = spawn_server(app: File.join(ROOT, "test/integration/env.ru"), config: <<~CONFIG)
      listen "#{addr}:#{port}"
      worker_processes 1

      service_thread = nil
      service_shutdown = false

      before_service_worker_ready do |server, service|
        service_thread = Thread.new do
          $stderr.puts "[service] start"
          count = 1
          until service_shutdown
            $stderr.puts "[service] ping count=\#{count}"
            count += 1
            sleep 1
          end
        end
      end

      before_service_worker_exit do |server, service|
        $stderr.puts "[service] exit"
        service_shutdown = true
        service_thread&.join(2)
      end
    CONFIG

    assert_healthy("http://#{addr}:#{port}")
    assert_stderr("[service] start")
    assert_stderr("[service] ping count=1")
    assert_stderr("[service] ping count=2")
    assert_clean_shutdown(pid)
    assert_stderr("[service] exit")
  end

  def test_start_only
    addr, port = unused_port

    pid = spawn_server(app: File.join(ROOT, "test/integration/env.ru"), config: <<~CONFIG)
      listen "#{addr}:#{port}"
      worker_processes 1

      before_service_worker_ready do |server, service|
        Thread.new do
          $stderr.puts "[service] start"
          count = 1
          loop do
            $stderr.puts "[service] ping count=\#{count}"
            count += 1
            sleep 1
          end
        end
      end
    CONFIG

    assert_healthy("http://#{addr}:#{port}")
    assert_stderr("[service] start")
    assert_stderr("[service] ping count=1")
    assert_stderr("[service] ping count=2")
    assert_clean_shutdown(pid)
  end
end

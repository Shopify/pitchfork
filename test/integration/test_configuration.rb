require 'integration_test_helper'

class ConfigurationTest < Pitchfork::IntegrationTest
  def test_after_request_complete
    addr, port = unused_port

    pid = spawn_server(app: File.join(ROOT, "test/integration/env.ru"), config: <<~CONFIG)
      listen "#{addr}:#{port}"
      worker_processes 1

      request_count = 0
      after_request_complete do |server, worker|
        request_count += 1
        $stderr.puts "[after_request_complete] request_count=\#{request_count}"
      end
    CONFIG

    assert_healthy("http://#{addr}:#{port}")
    assert_stderr("[after_request_complete] request_count=1")
    assert_healthy("http://#{addr}:#{port}")
    assert_stderr("[after_request_complete] request_count=2")

    assert_clean_shutdown(pid)
  end
end

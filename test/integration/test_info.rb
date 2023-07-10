require 'integration_test_helper'

class InfoTest < Pitchfork::IntegrationTest
  def test_after_request_complete
    addr, port = unused_port

    pid = spawn_server(app: File.join(ROOT, "test/integration/info.ru"), config: <<~CONFIG)
      listen "#{addr}:#{port}"
      worker_processes 1
    CONFIG

    assert_healthy("http://#{addr}:#{port}")

    response = http_get("http://#{addr}:#{port}/")
    assert_equal "{:workers_count=>1, :live_workers_count=>1}", response.body

    assert_clean_shutdown(pid)
  end
end

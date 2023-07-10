require 'integration_test_helper'

class InfoTest < Pitchfork::IntegrationTest
  def test_after_request_complete
    addr, port = unused_port

    pid = spawn_server(app: File.join(ROOT, "test/integration/info.ru"), config: <<~CONFIG)
      listen "#{addr}:#{port}"
      worker_processes 4
    CONFIG

    assert_healthy("http://#{addr}:#{port}")
    assert_stderr "worker=3 gen=0 ready"

    response = http_get("http://#{addr}:#{port}/")
    assert_equal "{:workers_count=>4, :live_workers_count=>4}", response.body

    Process.kill(:TTOU, pid)
    assert_stderr(/worker=3 pid=\d+ gen=0 reaped/)
    Process.kill(:TTOU, pid)
    assert_stderr(/worker=2 pid=\d+ gen=0 reaped/)

    response = http_get("http://#{addr}:#{port}/")
    assert_equal "{:workers_count=>4, :live_workers_count=>2}", response.body

    assert_clean_shutdown(pid)
  end
end

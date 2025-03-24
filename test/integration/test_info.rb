# frozen_string_literal: true
require 'integration_test_helper'

class InfoTest < Pitchfork::IntegrationTest
  def test_after_request_complete
    addr, port = unused_port

    pid = spawn_server(app: File.join(ROOT, "test/integration/info.ru"), config: <<~CONFIG)
      listen "#{addr}:#{port}"
      worker_processes 4
    CONFIG

    assert_healthy("http://#{addr}:#{port}")
    assert_stderr(/worker=3 gen=0 pid=\d+ ready/)

    response = http_get("http://#{addr}:#{port}/")
    assert_equal({workers_count: 4, live_workers_count: 4}.inspect, response.body)

    Process.kill(:TTOU, pid)
    assert_stderr(/worker=3 gen=0 pid=\d+ reaped/)
    Process.kill(:TTOU, pid)
    assert_stderr(/worker=2 gen=0 pid=\d+ reaped/)

    response = http_get("http://#{addr}:#{port}/")
    assert_equal({workers_count: 4, live_workers_count: 2}.inspect, response.body)

    assert_clean_shutdown(pid)
  end

  def test_live_workers_count_if_after_worker_fork_does_not_complete
    addr, port = unused_port

    _= spawn_server(app: File.join(ROOT, "test/integration/info.ru"), config: <<~CONFIG)
      listen "#{addr}:#{port}"
      worker_processes 20
      after_worker_fork { |_,w| if w.nr > 0 then sleep 100000 end }
    CONFIG

    assert_healthy("http://#{addr}:#{port}")

    response = http_get("http://#{addr}:#{port}/")

    assert_equal({workers_count: 20, live_workers_count: 1}.inspect, response.body)
  end
end

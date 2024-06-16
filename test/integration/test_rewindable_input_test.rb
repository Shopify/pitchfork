# frozen_string_literal: true
require "integration_test_helper"

class RewindableInputTest < Pitchfork::IntegrationTest
  def test_rewindable_input_false
    addr, port = unused_port

    pid = spawn_server(app: File.join(ROOT, "test/integration/apps/rack_input_class.ru"), lint: false, config: <<~CONFIG)
      listen "#{addr}:#{port}"
      worker_processes 1

      rewindable_input false
    CONFIG

    assert_healthy("http://#{addr}:#{port}")

    http = Net::HTTP.new(addr, port)
    assert_equal "Pitchfork::StreamInput", http.send_request("PUT", "/", "foo").body

    assert_clean_shutdown(pid)
  end

  def test_rewindable_input_true
    addr, port = unused_port

    pid = spawn_server(app: File.join(ROOT, "test/integration/apps/rack_input_class.ru"), lint: false, config: <<~CONFIG)
      listen "#{addr}:#{port}"
      worker_processes 1

      rewindable_input true
    CONFIG

    assert_healthy("http://#{addr}:#{port}")

    http = Net::HTTP.new(addr, port)
    assert_equal "Pitchfork::TeeInput", http.send_request("PUT", "/", "foo").body

    assert_clean_shutdown(pid)
  end
end

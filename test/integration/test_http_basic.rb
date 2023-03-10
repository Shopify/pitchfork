require 'integration_test_helper'

class HttpBasicTest < Pitchfork::IntegrationTest
  def test_http_basic
    addr, port = unused_port

    pid = spawn_server(app: File.join(ROOT, "test/integration/env.ru"), config: <<~CONFIG)
      listen "#{addr}:#{port}"
    CONFIG

    # Basic HTTP GET
    assert_healthy("http://#{addr}:#{port}")

    # HTTP/0.9 GET Request
    Socket.tcp(addr, port) do |sock|
      sock.print("GET /\r\n")
      sock.close_write
      result = sock.read

      assert_equal 1, result.split("\n").length
      refute result.start_with?("Connection:"), "Response contains unexpected header"
      refute result.start_with?("HTTP/"), "Response contains unexpected header"
    end

    assert_clean_shutdown(pid)
  end
end

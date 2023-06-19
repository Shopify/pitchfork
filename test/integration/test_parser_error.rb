# -*- encoding: binary -*-

require 'integration_test_helper'

class ParserErrorTest < Pitchfork::IntegrationTest
  # TODO: Move all cases into one test to avoid respawning separate servers?
  # Current approach is more Ruby, but is less performant.
  def test_bad_request
    addr, port = unused_port

    pid = spawn_server(app: File.join(ROOT, "test/integration/env.ru"), config: <<~CONFIG)
      listen "#{addr}:#{port}"
    CONFIG

    assert_healthy("http://#{addr}:#{port}")

    Socket.tcp(addr, port) do |sock|
      sock.print("GET / HTTP/1/1\r\nHost: example.com\r\n\r\n")
      sock.close_write
      result = sock.read

      assert_equal "HTTP/1.1 400 Bad Request\r\n\r\n", result
    end

    assert_clean_shutdown(pid)
  end

  def test_request_uri_too_large_because_request_path_length
    addr, port = unused_port

    pid = spawn_server(app: File.join(ROOT, "test/integration/env.ru"), config: <<~CONFIG)
      listen "#{addr}:#{port}"
    CONFIG

    assert_healthy("http://#{addr}:#{port}")

    large_request_uri = <<~REQUEST
      GET /#{1024.times.map { "0123456789ab" }.join} HTTP/1.1\r\nHost: example.com\r\n\r\n
    REQUEST

    Socket.tcp(addr, port) do |sock|
      sock.print(large_request_uri)
      sock.close_write
      result = sock.read

      assert_equal "HTTP/1.1 414 URI Too Long\r\n\r\n", result
    end

    assert_clean_shutdown(pid)
  end

  def test_request_uri_too_large_because_query_string_too_large
    addr, port = unused_port

    pid = spawn_server(app: File.join(ROOT, "test/integration/env.ru"), config: <<~CONFIG)
      listen "#{addr}:#{port}"
    CONFIG

    assert_healthy("http://#{addr}:#{port}")

    large_request_uri = <<~REQUEST
      GET /hello-world?a#{1024.times.map { "0123456789" }.join} HTTP/1.1\r\nHost: example.com\r\n\r\n
    REQUEST

    Socket.tcp(addr, port) do |sock|
      sock.print(large_request_uri)
      sock.close_write
      result = sock.read

      assert_equal "HTTP/1.1 414 URI Too Long\r\n\r\n", result
    end

    assert_clean_shutdown(pid)
  end

  def test_request_uri_too_large_because_fragment_length_too_large
    addr, port = unused_port

    pid = spawn_server(app: File.join(ROOT, "test/integration/env.ru"), config: <<~CONFIG)
      listen "#{addr}:#{port}"
    CONFIG

    assert_healthy("http://#{addr}:#{port}")

    large_request_uri = <<~REQUEST
      GET /hello-world#a#{64.times.map { "0123456789abcdef" }.join} HTTP/1.1\r\nHost: example.com\r\n\r\n
    REQUEST

    Socket.tcp(addr, port) do |sock|
      sock.print(large_request_uri)
      sock.close_write
      result = sock.read

      assert_equal "HTTP/1.1 414 URI Too Long\r\n\r\n", result
    end

    assert_clean_shutdown(pid)
  end

  def test_non_ascii_headers
    addr, port = unused_port

    pid = spawn_server(app: File.join(ROOT, "test/integration/env.ru"), config: <<~CONFIG)
      listen "#{addr}:#{port}"
    CONFIG

    assert_healthy("http://#{addr}:#{port}")

    request = <<~REQUEST
      GET /hello HTTP/1.1\r\nHost: localhost\r\ncookie: weird_utf8=\xC3\xB0\xC5\xB8\xC5\xA1\xC5\xA1;\r\n\r\n
    REQUEST

    Socket.tcp(addr, port) do |sock|
      sock.print(request)
      sock.close_write
      result = sock.read

      assert_equal "HTTP/1.1 200 OK", result.lines.first.strip
    end

    assert_clean_shutdown(pid)
  end
end

# frozen_string_literal: true
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

  def test_options_wildcard
    addr, port = unused_port

    pid = spawn_server(app: File.join(ROOT, "test/integration/env.ru"), config: <<~CONFIG)
      listen "#{addr}:#{port}"
    CONFIG

    # Basic HTTP GET
    assert_healthy("http://#{addr}:#{port}")

    # OPTIONS * HTTP/1.1
    Socket.tcp(addr, port) do |sock|
      sock.print("OPTIONS * HTTP/1.1\r\n\r\n")
      sock.close_write
      result = sock.read

      assert_equal "HTTP/1.1 200 OK", result.lines.first.strip
    end

    assert_clean_shutdown(pid)
  end

  def test_chunked_encoding
    addr, port = unused_port

    pid = spawn_server(app: File.join(ROOT, "test/integration/apps/chunked.ru"), config: <<~CONFIG)
      listen "#{addr}:#{port}"
      worker_processes 1
    CONFIG

    assert_healthy("http://#{addr}:#{port}")

    response = Net::HTTP.get_response(URI("http://#{addr}:#{port}"))
    assert_instance_of Net::HTTPOK, response
    assert_equal "chunked", response["transfer-encoding"]

    assert_clean_shutdown(pid)
  end

  def test_streaming_partial_hijack
    addr, port = unused_port

    if Rack::RELEASE < "3"
      skip("Partial hijack doesn't work in rack 2.x. because Rack::Lint and Rack::ContentLenght don't handle a nil body")
    end

    pid = spawn_server(app: File.join(ROOT, "test/integration/apps/streaming_hijack.ru"), config: <<~CONFIG)
      listen "#{addr}:#{port}"
      worker_processes 1
    CONFIG

    assert_healthy("http://#{addr}:#{port}/health")

    response = Net::HTTP.get_response(URI("http://#{addr}:#{port}/partial-hijack"))
    assert_equal "Partial Hijack", response.body

    assert_clean_shutdown(pid)
  end

  def test_streaming_full_hijack
    addr, port = unused_port

    pid = spawn_server(app: File.join(ROOT, "test/integration/apps/streaming_hijack.ru"), config: <<~CONFIG)
      listen "#{addr}:#{port}"
      worker_processes 1
    CONFIG

    assert_healthy("http://#{addr}:#{port}/health")

    response = Net::HTTP.get_response(URI("http://#{addr}:#{port}/full-hijack"))
    assert_equal "Full Hijack", response.body

    assert_clean_shutdown(pid)
  end

  def test_streaming_body
    addr, port = unused_port

    if Rack::RELEASE < "3"
      skip("Streaming Body doesn't work in rack 2.x. because Rack::Lint requires the body to respond to :each")
    end

    pid = spawn_server(app: File.join(ROOT, "test/integration/apps/streaming_body.ru"), config: <<~CONFIG)
      listen "#{addr}:#{port}"
      worker_processes 1
    CONFIG

    assert_healthy("http://#{addr}:#{port}")

    response = Net::HTTP.get_response(URI("http://#{addr}:#{port}"))
    assert_equal "Streaming Body", response.body

    assert_clean_shutdown(pid)
  end

  def test_write_on_close
    addr, port = unused_port

    pid = spawn_server(app: File.join(ROOT, "test/integration/apps/write-on-close.ru"), config: <<~CONFIG)
      listen "#{addr}:#{port}"
      worker_processes 1
    CONFIG

    assert_healthy("http://#{addr}:#{port}")

    response = Net::HTTP.get_response(URI("http://#{addr}:#{port}"))
    assert_equal "Goodbye", response.body

    assert_clean_shutdown(pid)
  end
end

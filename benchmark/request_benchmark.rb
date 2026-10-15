#!/usr/bin/env ruby
# frozen_string_literal: true

# Benchmarks the per-request Ruby-level hot path: HTTP parsing
# (Pitchfork::HttpParser#read) and response writing (http_response_write).
# This isolates the part of a request pitchfork controls in Ruby, without
# the noise of a real TCP stack, listener accept loop, or a Rack app.

require "socket"
require "fileutils"
require "benchmark/ips"
require "pitchfork"

#Headers emitted by Firefox when querying https://example.com
REQUEST = (<<~HTTP.split("\n").join("\r\n") << "\r\n\r\n").b
  GET /hello?foo=bar HTTP/1.1
  Host: example.com
  User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:157.0) Gecko/20100101 Firefox/157.0
  Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8
  Accept-Language: en-US,en;q=0.9
  Accept-Encoding: gzip, deflate, br, zstd
  Upgrade-Insecure-Requests: 1
  Connection: keep-alive
  Sec-Fetch-Dest: document
  Sec-Fetch-Mode: navigate
  Sec-Fetch-Site: none
  Sec-Fetch-User: ?1
  Priority: u=0, i
HTTP

BRANCH ||= ENV["BRANCH"] || begin
  branch = `git rev-parse --abbrev-ref HEAD`.strip
  branch = `git rev-parse HEAD`.strip if branch == "HEAD"
  branch
end

DATA_DIR = "/tmp/pitchfork-bench"

FileUtils.mkdir_p(DATA_DIR)

class RequestBench
  include Pitchfork::HttpResponse

  def initialize
    @client, @server = Socket.pair(:UNIX, :STREAM, 0)
    @body = ("Hello World!\n" * 1000).freeze
    @headers = { "content-type" => "text/plain", "content-length" => @body.bytesize.to_s }.freeze
    @server.setsockopt(:SOL_SOCKET, :SO_SNDBUF, @body.bytesize * 10)
    @buf = "".b
  end

  def run_once
    @client.write(REQUEST)
    req = Pitchfork::HttpParser.new
    env = req.read(@server)
    http_response_write(@server, 200, @headers, [@body], req)
    @client.readpartial(@body.bytesize * 2, @buf)
    env
  end
end

bench = RequestBench.new
env = bench.run_once
raise "sanity check failed" unless env["PATH_INFO"] == "/hello"

Benchmark.ips do |x|
  x.report(BRANCH) { bench.run_once }
  x.compare!(order: :baseline)
  x.save!(File.join(DATA_DIR, "request-response.data"))
end

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
    # Headers somewhat representative of a vanilla Rails app
    @headers = {
      "content-type" => "text/plain",
      "content-length" => @body.bytesize.to_s,
      "x-frame-options" => "SAMEORIGIN",
      "X-Xss-Protection" => "0",
      "X-Content-Type-Options" => "nosniff",
      "X-Permitted-Cross-Domain-Policies" => "none",
      "Referrer-Policy" => "strict-origin-when-cross-origin",
      "Link" => "</assets/ansi_stream.self-92d4ee1a07d3e06eb3145a4809f336213d91ae61be15427ab27b6015a10f0375.css?body=1>; rel=preload; as=style; nopush,</assets/clusterize.self-e800b47f82f06468feec0f3d7582faad615cbc3bd97086ce25fc6430347a314f.css?body=1>; rel=preload; as=style; nopush,</assets/shipit.self-9435813317a8e23afe88c6733ae24f084ec0a975b665ab91ba7a9885e6a16b8f.css?body=1>; rel=preload; as=style; nopush,</assets/jquery.self-bd7ddd393353a8d2480a622e80342adf488fb6006d667e8b42e4c0073393abee.js?body=1>; rel=preload; as=script; nopush,</assets/jquery_ujs.self-a6375ab2b275439c922ac52b02a475d288976458aa11a6e8103c925ef2961f66.js?body=1>; rel=preload; as=script; nopush,</assets/jquery.timeago.self-93eb9343105e184ba97229398b7379fd3b3a776e75caed52b1822caa85c7dc1c.js?body=1>; rel=preload; as=script; nopush,</assets/rails-timeago.self-e64fd06c0b47de91c2d4d8add679349965a5fc3d79df086ed5e05f9a453a7682.js?body=1>; rel=preload; as=script; nopush",
      "Vary" => "Accept",
      "Etag" => 'W/"53563805e72c3850a046b02bf8ccd7ef"',
      "Cache-Control" => "max-age=0, private, must-revalidate",
      "X-Request-Id" => "602a0bce-1d08-4730-bc82-7630faa2e848",
      "X-Runtime" => "0.022851",
      "Set-Cookie" => "_dummy_session=2TRV9WNdqO02QYfGpNf5cdIhOBumI3TsndmAabnE3WdjDcqF09XPpcVzTF9FJIU26xhpZW8yeKBIS5qQHpBlSs63YZIv6lWXShZjLe24V%2Bq2xt8JthapJwcuH56ONUMtoWHVdVzqqu%2BgrF96ckyaFqu9JYF0%2FPfwhLbmXSLfUCgbNE3QSTquCTzvxxtHK5dbVLYtvDpG74Z1j9vTO%2FNnuuuVPOu3LXPW6ZZhMk7OnMQ8jVLWEx8wkB3e1yn%2Bz32fvttYSgbs865E9w8voN65NfZLXgzgXw%3D%3D--R7jc4YqCjlFYV6pD--%2Bten7S%2FmnotUFK6mHStxpQ%3D%3D; path=/; HttpOnly; SameSite=Lax",
    }.freeze
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

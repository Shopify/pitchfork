#!/usr/bin/env ruby
# frozen_string_literal: true

# Benchmarks the per-request Ruby-level hot path: HTTP parsing
# (Pitchfork::HttpParser#read) and response writing (http_response_write).
# This isolates the part of a request pitchfork controls in Ruby, without
# the noise of a real TCP stack, listener accept loop, or a Rack app.
#
# Usage:
#   bundle exec benchmark/request_benchmark.rb            # benchmark-ips report
#   bundle exec benchmark/request_benchmark.rb profile N   # StackProf wall-clock profile, N iterations (default 200_000)
require "socket"
require "benchmark/ips"
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "pitchfork"

REQUEST = "GET /hello?foo=bar HTTP/1.1\r\nHost: example.com\r\nUser-Agent: bench\r\nAccept: */*\r\nConnection: close\r\n\r\n".b

class RequestBench
  include Pitchfork::HttpResponse

  def initialize
    @client, @server = Socket.pair(:UNIX, :STREAM, 0)
  end

  def run_once
    @client.write(REQUEST)
    req = Pitchfork::HttpParser.new
    env = req.read(@server)
    body = "Hello World!\n"
    headers = { "content-type" => "text/plain", "content-length" => body.bytesize.to_s }
    http_response_write(@server, 200, headers, [body], req)
    @client.readpartial(65536)
    env
  end
end

bench = RequestBench.new
env = bench.run_once
raise "sanity check failed" unless env["PATH_INFO"] == "/hello"

if ARGV[0] == "profile"
  require "stackprof"
  n = (ARGV[1] || 200_000).to_i
  out = File.join(__dir__, "stackprof-request_benchmark.dump")
  StackProf.run(mode: :wall, out: out, raw: true) do
    n.times { bench.run_once }
  end
  puts "wrote #{out}, inspect with: bundle exec stackprof #{out} --text"
else
  Benchmark.ips do |x|
    x.report("process request (parse+respond)") { bench.run_once }
  end
end

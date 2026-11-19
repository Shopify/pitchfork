# frozen_string_literal: true
require 'integration_test_helper'

class TestShutdown < Pitchfork::IntegrationTest
  SLOW_APP = <<~'RUBY'
    run lambda { |env|
      if (seconds = env["QUERY_STRING"].to_f) > 0
        $stderr.puts "request started pid=#{Process.pid}"
        sleep seconds
      end
      [200, {}, ["done\n"]]
    }
  RUBY

  test "TTIN during a graceful shutdown doesn't spawn workers" do
    addr, port = unused_port
    pid = spawn_server(app: write_app, config: <<~RUBY)
      listen "#{addr}:#{port}"
      worker_processes 1
    RUBY
    start_slow_request(addr, port, 3)

    Process.kill(:QUIT, pid)
    assert_stderr("QUIT received, starting graceful shutdown")
    Process.kill(:TTIN, pid)

    assert_exited(pid, 0, timeout: 6)
    refute_stderr(/worker=1|No mold alive/)
  end

  test "graceful shutdown doesn't busy-loop the monitor" do
    addr, port = unused_port
    pid = spawn_server(app: write_app, config: <<~RUBY)
      listen "#{addr}:#{port}"
      worker_processes 1
    RUBY
    start_slow_request(addr, port, 4)

    cpu_before = cpu_time(pid)
    Process.kill(:QUIT, pid)
    sleep 3
    assert_operator cpu_time(pid) - cpu_before, :<, 1.5

    assert_exited(pid, 0, timeout: 4)
  end

  private

  def write_app
    File.write("slow.ru", SLOW_APP)
    File.join(@pwd, "slow.ru")
  end

  def start_slow_request(addr, port, seconds)
    assert_healthy("http://#{addr}:#{port}")
    Thread.new { http_get("http://#{addr}:#{port}/?#{seconds}", timeout: seconds + 5) rescue nil }
    assert_stderr(/request started pid=\d+/, timeout: 5)
    Integer(read_stderr[/request started pid=(\d+)/, 1])
  end

  def cpu_time(pid)
    `ps -o time= -p #{pid}`.split(":").map(&:to_f).reverse.each_with_index.sum { |n, i| n * 60**i }
  end
end

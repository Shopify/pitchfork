require 'integration_test_helper'

class HearbeatTimeoutTest < Pitchfork::IntegrationTest
  def test_heartbeat_timeout
    timeout = 3
    addr, port = unused_port

    pid = spawn_server(app: File.join(ROOT, "test/integration/heartbeat-timeout.ru"), config: <<~CONFIG)
      listen "#{addr}:#{port}"
      timeout #{timeout}
    CONFIG

    assert_healthy("http://#{addr}:#{port}")

    # Get worker pid
    worker_pid = Net::HTTP.get(URI("http://#{addr}:#{port}/"))

    # Sleep Ruby process and ensure worker stays alive
    sleep(timeout + 1)
    assert_equal worker_pid, Net::HTTP.get(URI("http://#{addr}:#{port}/"))

    # GET request to block worker forever
    t0 = Time.now

    Socket.tcp(addr, port) do |sock|
      sock.print("GET /block-forever HTTP/1.1\r\nHost: example.com\r\n\r\n")
      sock.close_write
      sock.read
    end

    t1 = Time.now

    # Worker should have been killed
    assert_match(/pid=#{worker_pid.to_i}.*, killing$/, File.read("stderr.log"))

    assert (t1 - t0) > timeout, "Elapsed time was shorter than expected timeout of #{timeout} seconds"

    # Get new worker, pids shouldn't be same
    new_worker_pid = Net::HTTP.get(URI("http://#{addr}:#{port}/"))
    refute_equal worker_pid, new_worker_pid

    # SIGSTOP, wait, then SIGCONT master, worker shouldn't be affected
    Process.kill(:STOP, pid)
    sleep(timeout + 1)
    Process.kill(:CONT, pid)

    assert_equal new_worker_pid, Net::HTTP.get(URI("http://#{addr}:#{port}/"))

    assert_clean_shutdown(pid)
  end
end

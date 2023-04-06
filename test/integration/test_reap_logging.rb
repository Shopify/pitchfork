require 'integration_test_helper'

class ReapLoggingTest < Pitchfork::IntegrationTest
  AFTER_FORK_FILE = 'after_worker_fork'
  # TODO: This test is slow.
  def test_reap_worker_logging_messages
    addr, port = unused_port

    pid = spawn_server(app: File.join(ROOT, "test/integration/pid.ru"), config: <<~CONFIG,)
      listen "#{addr}:#{port}"
      after_worker_fork { |s,w| File.open('#{AFTER_FORK_FILE}','w') { |f| f.write '.' } }
    CONFIG

    assert_new_worker_forked

    assert_healthy("http://#{addr}:#{port}")

    w1_pid = Net::HTTP.get(URI("http://#{addr}:#{port}")).to_i
    Process.kill(:KILL, w1_pid)

    assert_new_worker_forked
    assert_stderr(/ERROR -- :.*pid=#{w1_pid}.*reaped/)

    w2_pid = Net::HTTP.get(URI("http://#{addr}:#{port}")).to_i
    Process.kill(:QUIT, w2_pid)

    assert_new_worker_forked
    assert_stderr(/INFO -- :.*pid=#{w2_pid}.*reaped/)

    assert_clean_shutdown(pid)
  end

  def assert_new_worker_forked
    new_worker_forked = false

    timeout = 15 # TODO: Graceful shutdown can take a while, might make sense to block-read with a FIFO pipe instead?

    (timeout * 2).times do
      if File.exist?(AFTER_FORK_FILE) && File.read(AFTER_FORK_FILE).strip == "."
        new_worker_forked = true
        break
      end

      sleep 0.5
    end

    File.truncate(AFTER_FORK_FILE, 0)
    assert new_worker_forked, "A worker did not write to after_worker_fork within #{timeout} seconds."
  end
end

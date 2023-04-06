require 'integration_test_helper'

class ReforkingTest < Pitchfork::IntegrationTest
  if Pitchfork::REFORKING_AVAILABLE
    def test_reforking
      addr, port = unused_port

      pid = spawn_server(app: File.join(ROOT, "test/integration/env.ru"), config: <<~CONFIG)
        listen "#{addr}:#{port}"
        worker_processes 2
        refork_after [5, 5]
      CONFIG

      assert_healthy("http://#{addr}:#{port}")
      assert_stderr "worker=0 gen=0 ready"
      assert_stderr "worker=1 gen=0 ready"

      9.times do
        assert_equal true, healthy?("http://#{addr}:#{port}")
      end

      assert_stderr "Refork condition met, promoting ourselves", timeout: 3
      assert_stderr "Terminating old mold pid="
      assert_stderr "worker=0 gen=1 ready"
      assert_stderr "worker=1 gen=1 ready"

      File.truncate("stderr.log", 0)

      9.times do
        assert_equal true, healthy?("http://#{addr}:#{port}")
      end

      assert_stderr "worker=0 gen=2 ready", timeout: 3
      assert_stderr "worker=1 gen=2 ready"

      assert_clean_shutdown(pid)
    end

    def test_reforking_broken_after_promotion_hook
      addr, port = unused_port

      pid = spawn_server(app: File.join(ROOT, "test/integration/env.ru"), config: <<~CONFIG)
        listen "#{addr}:#{port}"
        worker_processes 2
        refork_after [5, 5]
        after_promotion do |_server, mold|
          raise "Oops" if mold.generation > 0
        end
      CONFIG

      assert_healthy("http://#{addr}:#{port}")
      assert_stderr "worker=0 gen=0 ready"
      assert_stderr "worker=1 gen=0 ready"

      9.times do
        assert_equal true, healthy?("http://#{addr}:#{port}")
      end

      assert_stderr "Refork condition met, promoting ourselves", timeout: 3
      assert_stderr(/mold pid=\d+ gen=1 reaped/)

      assert_equal true, healthy?("http://#{addr}:#{port}")

      assert_clean_shutdown(pid)
    end
  end
end

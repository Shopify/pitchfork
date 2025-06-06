# frozen_string_literal: true
require 'integration_test_helper'

class RackPragmasTest < Pitchfork::IntegrationTest
  def test_keeps_rack_config_pragmas
    addr, port = unused_port

    pid = spawn_server("-E", "none", app: File.join(ROOT, "test/integration/frozen_string.ru"), lint: false, config: <<~CONFIG,)
      listen "#{addr}:#{port}"
    CONFIG

    assert_healthy("http://#{addr}:#{port}")
    assert_clean_shutdown(pid)
  end
end

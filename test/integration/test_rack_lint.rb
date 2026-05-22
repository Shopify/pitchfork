# frozen_string_literal: true
require 'integration_test_helper'

class RackLintTest < Pitchfork::IntegrationTest
  # `fails-rack-lint.ru` returns a header named "status", which Rack::Lint
  # rejects with a 500. On Rack 3+, Pitchfork no longer auto-inserts Rack::Lint
  # (it drops `rewind` from `rack.input` in a way that breaks Rails middleware,
  # see https://github.com/Shopify/pitchfork/issues/177), so the response should
  # come back from the app unchanged.
  def test_no_auto_rack_lint_on_rack_3
    skip("Only relevant on Rack 3+") unless defined?(Rack::RELEASE) && Rack::RELEASE >= "3"

    addr, port = unused_port

    # lint: true keeps the default RACK_ENV (which the Pitchfork CLI sets to
    # "development"). On Rack 2 this would inject Rack::Lint and the request
    # below would 500; on Rack 3+ the gate skips the insert and the app's body
    # comes through.
    pid = spawn_server(app: File.join(ROOT, "test/integration/fails-rack-lint.ru"), lint: true, config: <<~CONFIG)
      listen "#{addr}:#{port}"
    CONFIG

    assert_healthy("http://#{addr}:#{port}")

    response = Net::HTTP.get_response(URI("http://#{addr}:#{port}"))
    assert_equal 200, response.code.to_i
    assert_equal "Rack::Lint wasn't there if you see this", response.body.strip

    assert_clean_shutdown(pid)
  end
end

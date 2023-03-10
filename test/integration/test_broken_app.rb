require 'integration_test_helper'

class BrokenAppTest < Pitchfork::IntegrationTest
  def test_graceful_handling_of_broken_apps
    addr, port = unused_port

    pid = spawn_server("-E", "none", app: File.join(ROOT, "test/integration/broken-app.ru"), config: <<~CONFIG,)
      listen "#{addr}:#{port}"
    CONFIG

    assert_healthy("http://#{addr}:#{port}")

    # Normal Response
    assert_equal "OK", Net::HTTP.get(URI("http://#{addr}:#{port}")).strip

    # App Raising Exception
    response = Net::HTTP.get_response(URI("http://#{addr}:#{port}/raise"))

    assert_equal 500, response.code.to_i
    assert_instance_of(Net::HTTPInternalServerError, response)
    assert_stderr "app error: BAD (RuntimeError)"

    File.truncate("stderr.log", 0)

    # App Returning Bad Response
    response = Net::HTTP.get_response(URI("http://#{addr}:#{port}/nil"))
    assert_equal 500, response.code.to_i
    assert_instance_of(Net::HTTPInternalServerError, response)
    assert_stderr(/app error.*undefined method.*for nil/)

    # Try a few normal requests
    result = 5.times.map { Net::HTTP.get(URI("http://#{addr}:#{port}")).strip }
    assert_equal ["OK"], result.uniq

    assert_clean_shutdown(pid)
  end
end

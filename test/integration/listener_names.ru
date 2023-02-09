use Rack::ContentLength
use Rack::ContentType, "text/plain"
run(lambda { |_| [ 200, {}, [ Pitchfork.listener_names.inspect ] ] })

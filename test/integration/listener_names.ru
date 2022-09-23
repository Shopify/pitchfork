use Rack::ContentLength
use Rack::ContentType, "text/plain"
names = Pitchfork.listener_names.inspect
run(lambda { |_| [ 200, {}, [ names ] ] })

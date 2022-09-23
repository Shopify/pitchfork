use Rack::ContentLength
use Rack::ContentType, "text/plain"
names = Unicorn.listener_names.inspect
run(lambda { |_| [ 200, {}, [ names ] ] })

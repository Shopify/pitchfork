use Rack::ContentLength
use Rack::ContentType, "text/plain"
run lambda { |env|

  # our File objects for stderr/stdout should always be sync=true
  ok = $stderr.sync && $stdout.sync

  [ 200, {}, [ "#{ok}\n" ] ]
}

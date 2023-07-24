use Rack::ContentLength
use Rack::ContentType, "text/plain"
run lambda { |env|
  Pitchfork::Info.no_longer_fork_safe!
  [ 200, {}, [ env.inspect << "\n" ] ]
}

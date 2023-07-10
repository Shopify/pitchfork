use Rack::ContentLength
use Rack::ContentType, "text/plain"
run lambda { |env|
  info = {
    workers_count: Pitchfork::Info.workers_count,
    live_workers_count: Pitchfork::Info.live_workers_count,
  }

  [ 200, {}, [ info.inspect ] ]
}

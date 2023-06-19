use Rack::ContentLength
use Rack::ContentType, "text/plain"
run lambda { |env|
  if (duration = env["QUERY_STRING"].to_i) > 0
    sleep duration
    [ 200, {}, [ "Slept for #{duration} seconds" ] ]
  else
    [ 200, {}, [ env.inspect << "\n" ] ]
  end
}

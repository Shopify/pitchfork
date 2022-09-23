#\ -E none
use Rack::ContentLength
use Rack::ContentType, 'text/plain'
app = lambda do |env|
  case env['rack.input']
  when Pitchfork::StreamInput
    [ 200, {}, %w(OK) ]
  else
    [ 500, {}, %w(NO) ]
  end
end
run app

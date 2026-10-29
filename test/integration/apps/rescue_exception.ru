# frozen_string_literal: true
use Rack::ContentLength
use Rack::ContentType, "text/plain"
run lambda { |env|
  begin
    sleep env["QUERY_STRING"].to_i
    [ 200, {}, [ "pid=#{Process.pid}" ] ]
  rescue Exception => error
    [ 500, {}, [ "rescued #{error.class}" ] ]
  end
}

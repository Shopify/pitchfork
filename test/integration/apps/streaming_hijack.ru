run lambda { |env|
  if env["PATH_INFO"] == "/health"
    [200, {}, ["OK"]]
  elsif env["PATH_INFO"] == "/partial-hijack"
    callback = proc do |stream|
      stream.write "Partial Hijack"
      stream.close
    end

    [ 200, { "rack.hijack" => callback }, nil ]
  elsif env["PATH_INFO"] == "/full-hijack"
    stream = env["rack.hijack"].call
    stream.write "HTTP/1.1 200 OK\r\n"
    stream.write "\r\n"
    stream.write "Full Hijack"
    stream.close
    nil
  else
    [ 400, {}, ["Unexpected Request"]]
  end
}

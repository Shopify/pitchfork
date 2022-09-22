run(lambda { |env|
  body = "#{caller.size}\n"
  h = {
    "content-length" => body.size.to_s,
    "content-type" => "text/plain",
  }
  [ 200, h, [ body ] ]
})

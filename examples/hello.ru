run lambda { |env|
  /\A100-continue\z/i =~ env['HTTP_EXPECT'] and return [100, {}, []]
  body = "Hello World!\n"
  [ 200, { 'content-type' => 'text/plain', 'content-length' => body.bytesize.to_s }, [ body ] ]
}

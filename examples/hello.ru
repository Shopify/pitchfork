#\-E none
#
run lambda { |env|
  /\A100-continue\z/i =~ env['HTTP_EXPECT'] and return [100, {}, []]
  [ 200, { 'Content-Type' => 'application/octet-stream' }, [ "Hello World!\n" ] ]
}

class ChunkedBody
  def each(&block)
    ('A'..'Z').each do |char|
      yield char * 500
    end

    self
  end
end

run lambda { |env|
  /\A100-continue\z/i =~ env['HTTP_EXPECT'] and return [100, {}, []]
  [ 200, { 'content-type' => 'application/octet-stream' }, ChunkedBody.new ]
}

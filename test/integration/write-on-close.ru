# frozen_string_literal: true
class WriteOnClose
  def each(&block)
    @callback = block
  end

  def close
    @callback.call "7\r\nGoodbye\r\n0\r\n\r\n"
  end
end
use Rack::ContentType, "text/plain"
run(lambda { |_| [ 200, { 'transfer-encoding' => 'chunked' }, WriteOnClose.new ] })

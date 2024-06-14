# frozen_string_literal: true

run lambda { |env|
  callback = proc do |stream|
    stream.write "Streaming Body"
    stream.close
  end

  return [200, {}, callback]
}

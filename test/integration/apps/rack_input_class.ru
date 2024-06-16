# frozen_string_literal: true

app = lambda do |env|
  [ 200, {}, [env["rack.input"].class.name] ]
end
run app

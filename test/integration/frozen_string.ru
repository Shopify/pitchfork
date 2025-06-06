# frozen_string_literal: true

run lambda { |_env|
  if 'test'.frozen?
    [200, {}, []]
  else
    [500, {}, []]
  end
}

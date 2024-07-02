# frozen_string_literal: true
run lambda { |env|
  if env['HTTP_UPGRADE']
    [404, {}, ["Upgrade not supported"]]
  else
    [200, {}, ["Normal response"]]
  end
}

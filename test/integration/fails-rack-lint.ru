# This rack app returns a header with key named "status", which will cause
# Rack::Lint to throw an exception if it is present.  This
# is used to check whether Rack::Lint is in the stack or not.

run lambda {|env| return [200, { "status" => "fails-rack-lint"}, ["Rack::Lint wasn't there if you see this\n"]]}

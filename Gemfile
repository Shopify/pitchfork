# frozen_string_literal: true

source "https://rubygems.org"

gem 'megatest', '>= 0.1.1'
gem 'rake'
gem 'rake-compiler'
if ENV["RACK_VERSION"]
  gem "rack", ENV["RACK_VERSION"]
end

group :benchmark do
  gem "puma"
  gem "stackprof"
  gem "benchmark-ips"
end

gemspec

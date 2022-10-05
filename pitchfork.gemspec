# frozen_string_literal: true

require_relative "lib/pitchfork/version"

Gem::Specification.new do |s|
  s.name = %q{pitchfork}
  s.version = Pitchfork::VERSION
  s.authors = ['Jean Boussier']
  s.email = ["jean.boussier@gmail.com"]
  s.summary = 'Rack HTTP server for fast clients and Unix'
  s.description = File.read('README.md').split("\n\n")[1]
  s.extensions = %w(ext/pitchfork_http/extconf.rb)
  s.files = Dir.chdir(File.expand_path('..', __FILE__)) do
    %x(git ls-files -z).split("\x0").reject { |f| f.match(%r{^(test|spec|features|bin)/}) }
  end
  s.executables = s.files.grep(%r{^exe/}) { |f| File.basename(f) }
  s.homepage = 'https://github.com/Shopify/pitchfork'

  s.required_ruby_version = ">= 2.5.0"

  s.add_dependency(%q<raindrops>, '~> 0.7')
  s.add_dependency(%q<rack>)

  # Note: To avoid ambiguity, we intentionally avoid the SPDX-compatible
  # 'Ruby' here since Ruby 1.9.3 switched to BSD-2-Clause, but we
  # inherited our license from Mongrel when Ruby was at 1.8.
  # We cannot automatically switch licenses when Ruby changes.
  s.licenses = ['GPL-2.0+', 'Ruby-1.8']
end

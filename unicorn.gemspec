# -*- encoding: binary -*-

Gem::Specification.new do |s|
  s.name = %q{unicorn}
  s.version = (ENV['VERSION'] || '6.1.0').dup
  s.authors = ['unicorn hackers']
  s.summary = 'Rack HTTP server for fast clients and Unix'
  s.description = File.read('README.md').split("\n\n")[1]
  s.email = %q{unicorn-public@yhbt.net}
  s.extensions = %w(ext/pitchfork_http/extconf.rb)
  s.files = Dir.chdir(File.expand_path('..', __FILE__)) do
    %x(git ls-files -z).split("\x0").reject { |f| f.match(%r{^(test|spec|features|bin)/}) }
  end
  s.executables = s.files.grep(%r{^exe/}) { |f| File.basename(f) }
  s.homepage = 'https://yhbt.net/unicorn/'

  # 2.0.0 is the minimum supported version. We don't specify
  # a maximum version to make it easier to test pre-releases,
  # but we do warn users if they install unicorn on an untested
  # version in extconf.rb
  s.required_ruby_version = ">= 2.5.0"

  s.add_dependency(%q<raindrops>, '~> 0.7')
  s.add_dependency(%q<rack>)
  s.add_dependency(%q<child_subreaper>) # TODO: it's so small we should merge it.

  # Note: To avoid ambiguity, we intentionally avoid the SPDX-compatible
  # 'Ruby' here since Ruby 1.9.3 switched to BSD-2-Clause, but we
  # inherited our license from Mongrel when Ruby was at 1.8.
  # We cannot automatically switch licenses when Ruby changes.
  s.licenses = ['GPL-2.0+', 'Ruby-1.8']
end

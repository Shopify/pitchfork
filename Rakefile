# frozen_string_literal: true
require "bundler/gem_tasks"
require "rake/testtask"
require "rake/extensiontask"

Rake::TestTask.new("test:unit") do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/unit/**/test_*.rb"]
  t.options = '-v' if ENV['CI'] || ENV['VERBOSE']
  t.warning = true
end

Rake::TestTask.new("test:integration") do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/integration/**/test_*.rb"]
  t.options = '-v' if ENV['CI'] || ENV['VERBOSE']
  t.warning = true
end

namespace :test do
  # It's not so much that these tests are slow, but they tend to fork
  # and/or register signal handlers, so they if something goes wrong
  # they are likely to get stuck forever.
  # The unicorn test suite has historically ran them in individual process
  # so we continue to do that.
  task slow: :compile do
    tests = Dir["test/slow/**/*.rb"].flat_map do |test_file|
      File.read(test_file).scan(/def (test_\w+)/).map do |test|
        [test_file] + test
      end
    end
    tests.each do |file, test|
      sh "ruby", "-Ilib:test", file, "-n", test, "-v"
    end
  end

  # Unicorn had its own POSIX-shell based testing framework.
  # It's quite hard to work with and it would be good to convert all this
  # to Ruby integration tests, but while pitchfork is a moving target it's
  # preferable to edit the test suite as little as possible.
  task legacy_integration: :compile do
    File.write("test/integration/random_blob", File.read("/dev/random", 1_000_000))
    lib = File.expand_path("lib", __dir__)
    path = "#{File.expand_path("exe", __dir__)}:#{ENV["PATH"]}"
    old_path = ENV["PATH"]
    ENV["PATH"] = "#{path}:#{old_path}"
    begin
      Dir.chdir("test/integration") do
        Dir["t[0-9]*.sh"].each do |integration_test|
          sh("rm", "-rf", "trash")
          sh("mkdir", "trash")
          command = ["sh", integration_test]
          command << "-v" if ENV["VERBOSE"] || ENV["CI"]
          sh(*command)
        end
      end
    ensure
      ENV["PATH"] = old_path
    end
  end
end

Rake::ExtensionTask.new("pitchfork_http") do |ext|
  ext.ext_dir = 'ext/pitchfork_http'
  ext.lib_dir = 'lib/pitchfork'
end

task :ragel do
  Dir.chdir(File.expand_path("ext/pitchfork_http", __dir__)) do
    puts "* compiling pitchfork_http.rl"
    cmd = ["ragel", "-G2", "pitchfork_http.rl", "-o", "pitchfork_http.c"]
    system(*cmd) or raise "== #{cmd.join(' ')} failed =="
  end
end

task test: %i(test:unit test:slow test:integration test:legacy_integration)

task default: %i(ragel compile test)

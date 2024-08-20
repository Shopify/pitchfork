# frozen_string_literal: true
require "bundler/gem_tasks"
require "rake/extensiontask"

require "megatest/test_task"

namespace :test do
  Megatest::TestTask.create(:unit) do |t|
    t.tests = FileList["test/unit/**/test_*.rb"]
    t.deps << :compile
  end

  Megatest::TestTask.create(:integration) do |t|
    t.tests = FileList["test/integration/**/test_*.rb"]
    t.deps << :compile
  end

  # It's not so much that these tests are slow, but they tend to fork
  # and/or register signal handlers, so they if something goes wrong
  # they are likely to get stuck forever.
  # The unicorn test suite has historically ran them in individual process
  # so we continue to do that.
  Megatest::TestTask.create(:slow) do |t|
    t.tests = FileList["test/slow/**/test_*.rb"]
    t.deps << :compile
  end

  # Unicorn had its own POSIX-shell based testing framework.
  # It's quite hard to work with and it would be good to convert all this
  # to Ruby integration tests, but while pitchfork is a moving target it's
  # preferable to edit the test suite as little as possible.
  task legacy_integration: :compile do
    File.write("test/integration/random_blob", File.read("/dev/random", 1_000_000))
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

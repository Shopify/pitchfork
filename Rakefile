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

  task integration: :compile do
    File.write("test/integration/random_blob", File.read("/dev/random", 1_000_000))
    lib = File.expand_path("lib", __dir__)
    path = "#{File.expand_path("exe", __dir__)}:#{ENV["PATH"]}"
    Dir.chdir("test/integration") do
      Dir["t[0-9]*.sh"].each do |integration_test|
        sh("rm", "-rf", "trash")
        sh("mkdir", "trash")
        sh({ "PATH" => path }, "sh", integration_test)
      end
    end
  end
end

Rake::ExtensionTask.new("unicorn_http") do |ext|
  ext.ext_dir = 'ext/unicorn_http'
  ext.lib_dir = 'lib/unicorn'
end

task :ragel do
  Dir.chdir(File.expand_path("ext/unicorn_http", __dir__)) do
    puts "* compiling unicorn_http.rl"
    system("ragel", "-G2", "unicorn_http.rl", "-o", "unicorn_http.c") or raise "ragel #{ragel_file} failed"
  end
end

task test: %i(test:unit test:slow)

task default: %i(ragel compile test)

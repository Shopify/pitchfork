# frozen_string_literal: true
require 'integration_test_helper'

class RestartTest < Pitchfork::IntegrationTest
  def test_restart
    addr, port = unused_port

    File.write("Gemfile", <<~RUBY)
      source "https://rubygems.org"

      gem "pitchfork", path: #{ROOT.inspect}
    RUBY
    pid = spawn_server(app: File.join(ROOT, "test/integration/env.ru"), bundler: true, config: <<~RUBY)
      listen "#{addr}:#{port}"
      worker_processes 2

      restart_command_prefix ["bundle", "exec"]
    RUBY

    assert_healthy("http://#{addr}:#{port}")
    assert_stderr(/worker=0 gen=0.0 pid=\d+ ready/)
    assert_stderr(/worker=1 gen=0.0 pid=\d+ ready/)

    4.times do
      assert_equal true, healthy?("http://#{addr}:#{port}")
    end

    write_config(<<~RUBY)
      listen "#{addr}:#{port}"
      worker_processes 4

      restart_command_prefix ["bundle", "exec"]
    RUBY

    File.truncate("stderr.log", 0)
    Process.kill(:USR1, pid)

    assert_stderr(/monitor v=0 reexecuting/)
    assert_stderr(/monitor v=1 initializing with inherited state/)

    10.times do
      assert_equal true, healthy?("http://#{addr}:#{port}")
    end

    if Pitchfork::REFORKING_AVAILABLE
      assert_stderr(/Terminating old mold gen=0.0/, timeout: 2)
    end

    assert_stderr(/worker=2 gen=1.0 pid=\d+ ready/, timeout: 2)
    assert_stderr(/worker=3 gen=1.0 pid=\d+ ready/)
    assert_stderr(/worker=1 gen=1.0 pid=\d+ ready/, timeout: 2)
    assert_stderr(/worker=0 gen=1.0 pid=\d+ ready/)

    assert_clean_shutdown(pid)
  end

  def test_restart_listen_queues
    addr, port = unused_port

    File.write("Gemfile", <<~RUBY)
      source "https://rubygems.org"

      gem "pitchfork", path: #{ROOT.inspect}
    RUBY
    pid = spawn_server(app: File.join(ROOT, "test/integration/env.ru"), bundler: true, config: <<~RUBY)
      listen "#{addr}:#{port}", queues: 2
      worker_processes 4

      restart_command_prefix ["bundle", "exec"]
    RUBY

    assert_healthy("http://#{addr}:#{port}")
    assert_stderr(/worker=0 gen=0.0 pid=\d+ ready/)
    assert_stderr(/worker=1 gen=0.0 pid=\d+ ready/)

    4.times do
      assert_equal true, healthy?("http://#{addr}:#{port}")
    end

    File.truncate("stderr.log", 0)
    Process.kill(:USR1, pid)

    assert_stderr(/monitor v=0 reexecuting/)
    assert_stderr(/monitor v=1 initializing with inherited state/)

    10.times do
      assert_equal true, healthy?("http://#{addr}:#{port}")
    end

    if Pitchfork::REFORKING_AVAILABLE
      assert_stderr(/Terminating old mold gen=0.0/, timeout: 2)
    end

    assert_stderr(/worker=0 gen=1.0 pid=\d+ ready/, timeout: 2)
    assert_stderr(/worker=1 gen=1.0 pid=\d+ ready/)
    assert_stderr(/worker=3 gen=1.0 pid=\d+ ready/)

    assert_clean_shutdown(pid)
  end

  if Pitchfork::REFORKING_AVAILABLE
    # If the mold and monitor are the same process, we can't recover from a failed boot.
    def test_restart_mold_crash
      addr, port = unused_port

      File.write("Gemfile", <<~RUBY)
        source "https://rubygems.org"

        gem "pitchfork", path: #{ROOT.inspect}
      RUBY
      File.write("env.ru", File.read(File.join(ROOT, "test/integration/env.ru")))

      pid = spawn_server(app: "env.ru", bundler: true, config: <<~RUBY)
        listen "#{addr}:#{port}"
        worker_processes 2

        restart_command_prefix ["bundle", "exec"]
      RUBY

      assert_healthy("http://#{addr}:#{port}")
      assert_stderr(/worker=0 gen=0.0 pid=\d+ ready/)
      assert_stderr(/worker=1 gen=0.0 pid=\d+ ready/)

      write_config(<<~RUBY)
        listen "#{addr}:#{port}"
        worker_processes 2

        restart_command_prefix ["bundle", "exec"]
      RUBY

      File.write("env.ru", <<~RUBY)
        1 + "1" # TypeError
      RUBY

      Process.kill(:USR1, pid)

      assert_stderr(/monitor v=0 reexecuting/)
      assert_stderr(/monitor v=1 initializing with inherited state/)
      assert_stderr(/mold gen=1.0 pid=\d+ reaped .* exit 1/)
      assert_stderr(/mold gen=1.0 pid=\d+ crashed before being ready, restart cancelled/)
      assert_equal true, healthy?("http://#{addr}:#{port}")

      File.write("env.ru", <<~RUBY)
        run lambda { |env| [ 200, {}, [ "OK\n" ] ] }
      RUBY

      Process.kill(:USR1, pid)
      File.truncate("stderr.log", 0)
      assert_stderr(/mold gen=2.0 pid=\d+ spawned/)
      assert_stderr(/mold gen=2.0 pid=\d+ ready/)
      assert_stderr(/Terminating old mold gen=0.0/, timeout: 2)
      assert_stderr(/worker=1 gen=2.0 pid=\d+ ready/)
      assert_healthy("http://#{addr}:#{port}")

      assert_clean_shutdown(pid)
    end
  end

  def test_restart_worker_crash
    addr, port = unused_port

    File.write("Gemfile", <<~RUBY)
      source "https://rubygems.org"

      gem "pitchfork", path: #{ROOT.inspect}
    RUBY
    File.write("env.ru", File.read(File.join(ROOT, "test/integration/env.ru")))

    pid = spawn_server(app: "env.ru", bundler: true, config: <<~RUBY)
      listen "#{addr}:#{port}"
      worker_processes 2

      restart_command_prefix ["bundle", "exec"]
    RUBY

    assert_healthy("http://#{addr}:#{port}")
    assert_stderr(/worker=0 gen=0.0 pid=\d+ ready/)
    assert_stderr(/worker=1 gen=0.0 pid=\d+ ready/)

    write_config(<<~RUBY)
      listen "#{addr}:#{port}"
      worker_processes 2

      restart_command_prefix ["bundle", "exec"]

      after_worker_fork do |server, worker|
        exit 41
      end
    RUBY

    Process.kill(:USR1, pid)

    assert_stderr(/monitor v=0 reexecuting/)
    assert_stderr(/monitor v=1 initializing with inherited state/)

    3.times do
      File.truncate("stderr.log", 0)
      assert_stderr(/worker=0 gen=1.0 pid=\d+ reaped .* exit 41/)
      assert_equal true, healthy?("http://#{addr}:#{port}")
      refute_stderr(/worker=1 .* reaped/) # We never attempt to restart worker 1 because of `refork_max_unavailable`.
    end

    assert_equal true, healthy?("http://#{addr}:#{port}")

    write_config(<<~RUBY)
      listen "#{addr}:#{port}"
      worker_processes 2

      restart_command_prefix ["bundle", "exec"]
    RUBY

    Process.kill(:USR1, pid)
    assert_stderr(/monitor v=1 reexecuting/)
    assert_stderr(/monitor v=2 initializing with inherited state/)
    assert_healthy("http://#{addr}:#{port}")

    if Pitchfork::REFORKING_AVAILABLE
      assert_stderr(/mold gen=2.0 pid=\d+ ready/, timeout: 2)
      assert_stderr(/Terminating old mold gen=1.0/)
      assert_stderr(/mold gen=1.0 pid=\d+ reaped/, timeout: 2)
    end

    assert_stderr(/worker=0 gen=2.0 pid=\d+ ready/, timeout: 4)
    assert_stderr(/worker=1 gen=2.0 pid=\d+ ready/)

    assert_healthy("http://#{addr}:#{port}")

    assert_clean_shutdown(pid)
  end

  def test_restart_service
    addr, port = unused_port

    File.write("Gemfile", <<~RUBY)
      source "https://rubygems.org"

      gem "pitchfork", path: #{ROOT.inspect}
    RUBY
    pid = spawn_server(app: File.join(ROOT, "test/integration/env.ru"), bundler: true, config: <<~RUBY)
      listen "#{addr}:#{port}"
      worker_processes 2

      restart_command_prefix ["bundle", "exec"]

      before_service_worker_ready do |server, worker|
        5.times do |i|
          server.logger.info("\#{worker.to_log} v=0 ping=\#{i}")
          sleep 0.2
        end
      end
    RUBY

    assert_healthy("http://#{addr}:#{port}")
    assert_stderr(/service gen=0.0 pid=\d+ v=0 ping=2/)

    write_config(<<~RUBY)
      listen "#{addr}:#{port}"
      worker_processes 2

      restart_command_prefix ["bundle", "exec"]
      before_service_worker_ready do |server, worker|
        5.times do |i|
          server.logger.info("\#{worker.to_log} v=1 ping=\#{i}")
          sleep 0.2
        end
      end
    RUBY

    File.truncate("stderr.log", 0)
    Process.kill(:USR1, pid)

    assert_stderr(/monitor v=0 reexecuting/)
    assert_stderr(/monitor v=1 initializing with inherited state/)
    assert_stderr(/service gen=1.0 pid=\d+ v=1 ping=2/)
  end

  def test_restart_capistrano_link_releases
    addr, port = unused_port

    current_release = File.expand_path("current")
    Dir.mkdir("releases")

    %w(a b).each do |release|
      root = File.join("releases", release)
      Dir.mkdir(root)
      Dir.chdir(root) do
        File.write("config.ru", <<~RUBY)
          run lambda { |env| [ 200, {}, [ Dir.pwd ] ] }
        RUBY

        File.write("Gemfile", <<~RUBY)
          source "https://rubygems.org"

          gem "pitchfork", path: #{ROOT.inspect}
        RUBY

        assert system("bundle", "install", out: File::NULL, err: File::NULL)

        write_config(<<~RUBY)
          listen "#{addr}:#{port}"
          worker_processes 2

          working_directory '#{current_release}'
          restart_command_prefix ["bundle", "exec"]
        RUBY
      end
    end

    File.symlink(File.expand_path("releases/a"), "current")
    pid = Dir.chdir(File.realpath(current_release)) do
      Bundler.with_unbundled_env do
        Process.spawn("bundle", "exec", "pitchfork", "-c", "pitchfork.conf.rb", out: File.join(@pwd, "stdout.log"), err: File.join(@pwd, "stderr.log"))
      end
    end

    assert_stderr(/worker=1 gen=0.0 pid=\d+ ready/, timeout: 5)

    assert_healthy("http://#{addr}:#{port}")
    assert_equal File.expand_path("releases/a"), http_get("http://#{addr}:#{port}").body

    File.symlink(File.expand_path("releases/b"), "current.tmp")
    File.rename("current.tmp", "current")
    Process.kill(:SIGUSR1, pid)
    assert_equal File.expand_path("releases/b"), File.realpath("current")

    assert_stderr(/worker=1 gen=1.0 pid=\d+ ready/, timeout: 5)

    assert_healthy("http://#{addr}:#{port}")

    assert_equal File.expand_path("releases/b"), http_get("http://#{addr}:#{port}").body

    assert_clean_shutdown(pid)
  end
end

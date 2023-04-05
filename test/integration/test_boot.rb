require 'integration_test_helper'

class TestBoot < Pitchfork::IntegrationTest
  ROOT = File.expand_path('../../', __dir__)
  BIN = File.join(ROOT, 'exe/pitchfork')
  APP = File.join(ROOT, "examples/hello.ru")

  def setup
    super

    @_old_pwd = Dir.pwd
    @_pids = []
    @pwd = Dir.mktmpdir('pitchfork')
    Dir.chdir(@pwd)
  end

  def teardown
    pids = @_pids.select do |pid|
      Process.kill('INT', pid)
      true
    rescue Errno::ESRCH
      false
    end

    pids.reject! do |pid|
      Process.wait(pid, Process::WNOHANG)
    rescue Errno::ESRCH, Errno::ECHILD
      true
    end

    unless pids.empty?
      sleep 0.2
    end

    pids.reject! do |pid|
      Process.wait(pid, Process::WNOHANG)
    rescue Errno::ESRCH, Errno::ECHILD
      true
    end

    pids.reject! do |pid|
      Process.kill('KILL', pid)
      false
    rescue Errno::ESRCH
      true
    end

    pids.each do |pid|
      Process.wait(pid)
    end

    Dir.chdir(@_old_pwd)
    if passed?
      FileUtils.rm_rf(@pwd)
    else
      $stderr.puts("Working directory left at: #{@pwd}")
    end
  end

  def test_boot_minimal
    addr, port = unused_port

    pid = spawn_server(app: APP, config: <<~RUBY)
      listen "#{addr}:#{port}"
      worker_processes 2
      refork_after [50, 100, 1000]
    RUBY

    assert_healthy("http://#{addr}:#{port}")
    assert_clean_shutdown(pid)
  end

  def test_boot_broken_after_promotion
    addr, port = unused_port

    pid = spawn_server(app: APP, config: <<~RUBY)
      listen "#{addr}:#{port}"
      worker_processes 2
      refork_after [50, 100, 1000]
      after_promotion do |_server, _mold|
        raise "Oops"
      end
    RUBY

    assert_exited(pid, 1)
  end
end

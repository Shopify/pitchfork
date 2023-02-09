require 'test_helper'

class TestBoot < Pitchfork::Test
  ROOT = File.expand_path('../../', __dir__)
  BIN = File.join(ROOT, 'exe/pitchfork')
  DEFAULT_APP = File.join(ROOT, "examples/hello.ru")

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
    pid = spawn_server(config: <<~RUBY)
      worker_processes 2 # this should be >= nr_cpus
      refork_after [50, 100, 1000]
    RUBY

    assert_healthy
    assert_clean_shutdown(pid)
  end

  def test_boot_broken_after_promotion
    pid = spawn_server(config: <<~RUBY)
      worker_processes 2 # this should be >= nr_cpus
      refork_after [50, 100, 1000]
      after_promotion do |_server, _worker|
        raise "Oops"
      end
    RUBY

    assert_exited(pid, 1)
  end

  private

  def spawn_server(app: DEFAULT_APP, config: nil)
    File.write("pitchfork.conf.rb", config)
    spawn(BIN, "-c", "pitchfork.conf.rb", app)
  end

  def assert_clean_shutdown(pid, timeout = 4)
    Process.kill("QUIT", pid)
    status = nil
    (timeout * 2).times do
      Process.kill(0, pid)
      break if status = Process.wait2(pid, Process::WNOHANG)
      sleep 0.5
    end
    refute_nil status
    assert_predicate status[1], :success?
  end

  def assert_exited(pid, exitstatus, timeout = 4)
    status = nil
    (timeout * 2).times do
      break if status = Process.wait2(pid, Process::WNOHANG)
      sleep 0.5
    end
    refute_nil status
    assert_equal exitstatus, status[1].exitstatus
  end

  def assert_healthy(timeout = 2)
    assert wait_healthy?(timeout), "Expected server to be healthy but it wasn't"
  end

  def wait_healthy?(timeout)
    (timeout * 10).times do
      return true if healthy?
      sleep 0.1
    end
    false
  end

  def healthy?
    Net::HTTP.get(URI("http://localhost:8080/"))
    true
  rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL
    false
  end

  def spawn(*args)
    env = args.first.is_a?(Hash) ? args.unshift : {}
    pid = Process.spawn(env, *args, out: "stdout.log", err: "stderr.log")
    @_pids << pid
    pid
  end
end

# -*- encoding: binary -*-

# Copyright (c) 2009 Eric Wong
FLOCK_PATH = File.expand_path(__FILE__)
require './test/test_helper'

do_test = true
$unicorn_bin = ENV['UNICORN_TEST_BIN'] || "unicorn"
redirect_test_io do
  do_test = system($unicorn_bin, '-v')
end

unless do_test
  warn "#{$unicorn_bin} not found in PATH=#{ENV['PATH']}, " \
       "skipping this test"
end

unless try_require('rack')
  warn "Unable to load Rack, skipping this test"
  do_test = false
end

class ExecTest < Test::Unit::TestCase
  trap(:QUIT, 'IGNORE')

  HI = <<-EOS
use Rack::ContentLength
run proc { |env| [ 200, { 'Content-Type' => 'text/plain' }, [ "HI\\n" ] ] }
  EOS

  SHOW_RACK_ENV = <<-EOS
use Rack::ContentLength
run proc { |env|
  [ 200, { 'Content-Type' => 'text/plain' }, [ ENV['RACK_ENV'] ] ]
}
  EOS

  HELLO = <<-EOS
class Hello
  def call(env)
    [ 200, { 'Content-Type' => 'text/plain' }, [ "HI\\n" ] ]
  end
end
  EOS

  COMMON_TMP = Tempfile.new('unicorn_tmp') unless defined?(COMMON_TMP)

  HEAVY_WORKERS = 2
  HEAVY_CFG = <<-EOS
worker_processes #{HEAVY_WORKERS}
timeout 30
logger Logger.new('#{COMMON_TMP.path}')
before_fork do |server, worker|
  server.logger.info "before_fork: worker=\#{worker.nr}"
end
  EOS

  WORKING_DIRECTORY_CHECK_RU = <<-EOS
use Rack::ContentLength
run lambda { |env|
  pwd = ENV['PWD']
  a = ::File.stat(pwd)
  b = ::File.stat(Dir.pwd)
  if (a.ino == b.ino && a.dev == b.dev)
    [ 200, { 'Content-Type' => 'text/plain' }, [ pwd ] ]
  else
    [ 404, { 'Content-Type' => 'text/plain' }, [] ]
  end
}
  EOS

  def setup
    @pwd = Dir.pwd
    @tmpfile = Tempfile.new('unicorn_exec_test')
    @tmpdir = @tmpfile.path
    @tmpfile.close!
    Dir.mkdir(@tmpdir)
    Dir.chdir(@tmpdir)
    @addr = ENV['UNICORN_TEST_ADDR'] || '127.0.0.1'
    @port = unused_port(@addr)
    @sockets = []
    @start_pid = $$
  end

  def teardown
    return if @start_pid != $$
    Dir.chdir(@pwd)
    FileUtils.rmtree(@tmpdir)
    @sockets.each { |path| File.unlink(path) rescue nil }
    loop do
      Process.kill('-QUIT', 0)
      begin
        Process.waitpid(-1, Process::WNOHANG) or break
      rescue Errno::ECHILD
        break
      end
    end
  end

  def test_sd_listen_fds_emulation
    # [ruby-core:69895] [Bug #11336] fixed by r51576
    return if RUBY_VERSION.to_f < 2.3

    File.open("config.ru", "wb") { |fp| fp.write(HI) }
    sock = TCPServer.new(@addr, @port)

    [ %W(-l #@addr:#@port), nil ].each do |l|
      sock.setsockopt(:SOL_SOCKET, :SO_KEEPALIVE, 0)

      pid = xfork do
        redirect_test_io do
          # pretend to be systemd
          ENV['LISTEN_PID'] = "#$$"
          ENV['LISTEN_FDS'] = '1'

          # 3 = SD_LISTEN_FDS_START
          args = [ $unicorn_bin ]
          args.concat(l) if l
          args << { 3 => sock }
          exec(*args)
        end
      end
      res = hit(["http://#@addr:#@port/"])
      assert_equal [ "HI\n" ], res
      assert_shutdown(pid)
      assert sock.getsockopt(:SOL_SOCKET, :SO_KEEPALIVE).bool,
                  'unicorn should always set SO_KEEPALIVE on inherited sockets'
    end
  ensure
    sock.close if sock
  end

  def test_inherit_listener_unspecified
    File.open("config.ru", "wb") { |fp| fp.write(HI) }
    sock = TCPServer.new(@addr, @port)
    sock.setsockopt(:SOL_SOCKET, :SO_KEEPALIVE, 0)

    pid = xfork do
      redirect_test_io do
        ENV['UNICORN_FD'] = sock.fileno.to_s
        exec($unicorn_bin, sock.fileno => sock.fileno)
      end
    end
    res = hit(["http://#@addr:#@port/"])
    assert_equal [ "HI\n" ], res
    assert_shutdown(pid)
    assert sock.getsockopt(:SOL_SOCKET, :SO_KEEPALIVE).bool,
                'unicorn should always set SO_KEEPALIVE on inherited sockets'
  ensure
    sock.close if sock
  end

  def test_working_directory_rel_path_config_file
    other = Tempfile.new('unicorn.wd')
    File.unlink(other.path)
    Dir.mkdir(other.path)
    File.open("config.ru", "wb") do |fp|
      fp.syswrite WORKING_DIRECTORY_CHECK_RU
    end
    FileUtils.cp("config.ru", other.path + "/config.ru")
    Dir.chdir(@tmpdir)

    tmp = File.open('unicorn.config', 'wb')
    tmp.syswrite <<EOF
working_directory '#@tmpdir'
listen '#@addr:#@port'
EOF
    pid = xfork { redirect_test_io { exec($unicorn_bin, "-c#{tmp.path}") } }
    wait_workers_ready("test_stderr.#{pid}.log", 1)
    results = hit(["http://#@addr:#@port/"])
    assert_equal @tmpdir, results.first
    File.truncate("test_stderr.#{pid}.log", 0)

    tmp.sysseek(0)
    tmp.truncate(0)
    tmp.syswrite <<EOF
working_directory '#{other.path}'
listen '#@addr:#@port'
EOF

    Process.kill(:HUP, pid)
    lines = []
    re = /config_file=(.+) would not be accessible in working_directory=(.+)/
    until lines.grep(re)
      sleep 0.1
      lines = File.readlines("test_stderr.#{pid}.log")
    end

    File.truncate("test_stderr.#{pid}.log", 0)
    FileUtils.cp('unicorn.config', other.path + "/unicorn.config")
    Process.kill(:HUP, pid)
    wait_workers_ready("test_stderr.#{pid}.log", 1)
    results = hit(["http://#@addr:#@port/"])
    assert_equal other.path, results.first

    Process.kill(:QUIT, pid)
  ensure
    FileUtils.rmtree(other.path)
  end

  def test_working_directory
    other = Tempfile.new('unicorn.wd')
    File.unlink(other.path)
    Dir.mkdir(other.path)
    File.open("config.ru", "wb") do |fp|
      fp.syswrite WORKING_DIRECTORY_CHECK_RU
    end
    FileUtils.cp("config.ru", other.path + "/config.ru")
    tmp = Tempfile.new('unicorn.config')
    tmp.syswrite <<EOF
working_directory '#@tmpdir'
listen '#@addr:#@port'
EOF
    pid = xfork { redirect_test_io { exec($unicorn_bin, "-c#{tmp.path}") } }
    wait_workers_ready("test_stderr.#{pid}.log", 1)
    results = hit(["http://#@addr:#@port/"])
    assert_equal @tmpdir, results.first
    File.truncate("test_stderr.#{pid}.log", 0)

    tmp.sysseek(0)
    tmp.truncate(0)
    tmp.syswrite <<EOF
working_directory '#{other.path}'
listen '#@addr:#@port'
EOF

    Process.kill(:HUP, pid)
    wait_workers_ready("test_stderr.#{pid}.log", 1)
    results = hit(["http://#@addr:#@port/"])
    assert_equal other.path, results.first

    Process.kill(:QUIT, pid)
  ensure
    FileUtils.rmtree(other.path)
  end

  def test_working_directory_controls_relative_paths
    other = Tempfile.new('unicorn.wd')
    File.unlink(other.path)
    Dir.mkdir(other.path)
    File.open("config.ru", "wb") do |fp|
      fp.syswrite WORKING_DIRECTORY_CHECK_RU
    end
    FileUtils.cp("config.ru", other.path + "/config.ru")
    system('mkfifo', "#{other.path}/fifo")
    tmp = Tempfile.new('unicorn.config')
    tmp.syswrite <<EOF
pid "pid_file_here"
stderr_path "stderr_log_here"
stdout_path "stdout_log_here"
working_directory '#{other.path}'
listen '#@addr:#@port'
after_fork do |server, worker|
  File.open("fifo", "wb").close
end
EOF
    pid = xfork { redirect_test_io { exec($unicorn_bin, "-c#{tmp.path}") } }
    File.open("#{other.path}/fifo", "rb").close

    assert ! File.exist?("stderr_log_here")
    assert ! File.exist?("stdout_log_here")
    assert ! File.exist?("pid_file_here")

    assert ! File.exist?("#@tmpdir/stderr_log_here")
    assert ! File.exist?("#@tmpdir/stdout_log_here")
    assert ! File.exist?("#@tmpdir/pid_file_here")

    assert File.exist?("#{other.path}/pid_file_here")
    assert_equal "#{pid}\n", File.read("#{other.path}/pid_file_here")
    assert File.exist?("#{other.path}/stderr_log_here")
    assert File.exist?("#{other.path}/stdout_log_here")
    wait_master_ready("#{other.path}/stderr_log_here")

    Process.kill(:QUIT, pid)
  ensure
    FileUtils.rmtree(other.path)
  end

  def test_exit_signals
    %w(INT TERM QUIT).each do |sig|
      File.open("config.ru", "wb") { |fp| fp.syswrite(HI) }
      pid = xfork { redirect_test_io { exec($unicorn_bin, "-l#@addr:#@port") } }
      wait_master_ready("test_stderr.#{pid}.log")
      wait_workers_ready("test_stderr.#{pid}.log", 1)

      Process.kill(sig, pid)
      pid, status = Process.waitpid2(pid)

      reaped = File.readlines("test_stderr.#{pid}.log").grep(/reaped/)
      assert_equal 1, reaped.size
      assert status.exited?
    end
  end

  def test_basic
    File.open("config.ru", "wb") { |fp| fp.syswrite(HI) }
    pid = fork do
      redirect_test_io { exec($unicorn_bin, "-l", "#{@addr}:#{@port}") }
    end
    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal String, results[0].class
    assert_shutdown(pid)
  end

  def test_rack_env_unset
    File.open("config.ru", "wb") { |fp| fp.syswrite(SHOW_RACK_ENV) }
    pid = fork { redirect_test_io { exec($unicorn_bin, "-l#@addr:#@port") } }
    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal "development", results.first
    assert_shutdown(pid)
  end

  def test_rack_env_cli_set
    File.open("config.ru", "wb") { |fp| fp.syswrite(SHOW_RACK_ENV) }
    pid = fork {
      redirect_test_io { exec($unicorn_bin, "-l#@addr:#@port", "-Easdf") }
    }
    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal "asdf", results.first
    assert_shutdown(pid)
  end

  def test_rack_env_ENV_set
    File.open("config.ru", "wb") { |fp| fp.syswrite(SHOW_RACK_ENV) }
    pid = fork {
      ENV["RACK_ENV"] = "foobar"
      redirect_test_io { exec($unicorn_bin, "-l#@addr:#@port") }
    }
    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal "foobar", results.first
    assert_shutdown(pid)
  end

  def test_rack_env_cli_override_ENV
    File.open("config.ru", "wb") { |fp| fp.syswrite(SHOW_RACK_ENV) }
    pid = fork {
      ENV["RACK_ENV"] = "foobar"
      redirect_test_io { exec($unicorn_bin, "-l#@addr:#@port", "-Easdf") }
    }
    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal "asdf", results.first
    assert_shutdown(pid)
  end

  def test_ttin_ttou
    File.open("config.ru", "wb") { |fp| fp.syswrite(HI) }
    pid = fork { redirect_test_io { exec($unicorn_bin, "-l#@addr:#@port") } }
    log = "test_stderr.#{pid}.log"
    wait_master_ready(log)
    [ 2, 3].each { |i|
      Process.kill(:TTIN, pid)
      wait_workers_ready(log, i)
    }
    File.truncate(log, 0)
    reaped = nil
    [ 2, 1, 0].each { |i|
      Process.kill(:TTOU, pid)
      DEFAULT_TRIES.times {
        sleep DEFAULT_RES
        reaped = File.readlines(log).grep(/reaped.*\s*worker=#{i}$/)
        break if reaped.size == 1
      }
      assert_equal 1, reaped.size
    }
  end

  def test_help
    redirect_test_io do
      assert(system($unicorn_bin, "-h"), "help text returns true")
    end
    assert_equal 0, File.stat("test_stderr.#$$.log").size
    assert_not_equal 0, File.stat("test_stdout.#$$.log").size
    lines = File.readlines("test_stdout.#$$.log")

    # Be considerate of the on-call technician working from their
    # mobile phone or netbook on a slow connection :)
    assert lines.size <= 24, "help height fits in an ANSI terminal window"
    lines.each do |line|
      line.chomp!
      assert line.size <= 80, "help width fits in an ANSI terminal window"
    end
  end

  def test_unicorn_config_listener_swap
    port_cli = unused_port
    File.open("config.ru", "wb") { |fp| fp.syswrite(HI) }
    ucfg = Tempfile.new('unicorn_test_config')
    ucfg.syswrite("listen '#@addr:#@port'\n")
    pid = xfork do
      redirect_test_io do
        exec($unicorn_bin, "-c#{ucfg.path}", "-l#@addr:#{port_cli}")
      end
    end
    results = retry_hit(["http://#@addr:#{port_cli}/"])
    assert_equal String, results[0].class
    results = retry_hit(["http://#@addr:#@port/"])
    assert_equal String, results[0].class

    port2 = unused_port(@addr)
    ucfg.sysseek(0)
    ucfg.truncate(0)
    ucfg.syswrite("listen '#@addr:#{port2}'\n")
    Process.kill(:HUP, pid)

    results = retry_hit(["http://#@addr:#{port2}/"])
    assert_equal String, results[0].class
    results = retry_hit(["http://#@addr:#{port_cli}/"])
    assert_equal String, results[0].class
    reuse = TCPServer.new(@addr, @port)
    reuse.close
    assert_shutdown(pid)
  end

  def test_unicorn_config_listen_with_options
    File.open("config.ru", "wb") { |fp| fp.syswrite(HI) }
    ucfg = Tempfile.new('unicorn_test_config')
    ucfg.syswrite("listen '#{@addr}:#{@port}', :backlog => 512,\n")
    ucfg.syswrite("                            :rcvbuf => 4096,\n")
    ucfg.syswrite("                            :sndbuf => 4096\n")
    pid = xfork do
      redirect_test_io { exec($unicorn_bin, "-c#{ucfg.path}") }
    end
    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal String, results[0].class
    assert_shutdown(pid)
  end

  def test_unicorn_config_per_worker_listen
    port2 = unused_port
    pid_spit = 'use Rack::ContentLength;' \
      'run proc { |e| [ 200, {"Content-Type"=>"text/plain"}, ["#$$\\n"] ] }'
    File.open("config.ru", "wb") { |fp| fp.syswrite(pid_spit) }
    tmp = Tempfile.new('test.socket')
    File.unlink(tmp.path)
    ucfg = Tempfile.new('unicorn_test_config')
    ucfg.syswrite("listen '#@addr:#@port'\n")
    ucfg.syswrite("after_fork { |s,w|\n")
    ucfg.syswrite("  s.listen('#{tmp.path}', :backlog => 5, :sndbuf => 8192)\n")
    ucfg.syswrite("  s.listen('#@addr:#{port2}', :rcvbuf => 8192)\n")
    ucfg.syswrite("\n}\n")
    pid = xfork do
      redirect_test_io { exec($unicorn_bin, "-c#{ucfg.path}") }
    end
    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal String, results[0].class
    worker_pid = results[0].to_i
    assert_not_equal pid, worker_pid
    s = unix_socket(tmp.path)
    s.syswrite("GET / HTTP/1.0\r\n\r\n")
    results = ''
    loop { results << s.sysread(4096) } rescue nil
    s.close
    assert_equal worker_pid, results.split(/\r\n/).last.to_i
    results = hit(["http://#@addr:#{port2}/"])
    assert_equal String, results[0].class
    assert_equal worker_pid, results[0].to_i
    assert_shutdown(pid)
  end

  def test_unicorn_config_listen_augments_cli
    port2 = unused_port(@addr)
    File.open("config.ru", "wb") { |fp| fp.syswrite(HI) }
    ucfg = Tempfile.new('unicorn_test_config')
    ucfg.syswrite("listen '#{@addr}:#{@port}'\n")
    pid = xfork do
      redirect_test_io do
        exec($unicorn_bin, "-c#{ucfg.path}", "-l#{@addr}:#{port2}")
      end
    end
    uris = [@port, port2].map { |i| "http://#{@addr}:#{i}/" }
    results = retry_hit(uris)
    assert_equal results.size, uris.size
    assert_equal String, results[0].class
    assert_equal String, results[1].class
    assert_shutdown(pid)
  end

  def test_weird_config_settings
    File.open("config.ru", "wb") { |fp| fp.syswrite(HI) }
    ucfg = Tempfile.new('unicorn_test_config')
    proc_total = HEAVY_WORKERS + 1 # + 1 for master
    ucfg.syswrite(HEAVY_CFG)
    pid = xfork do
      redirect_test_io do
        exec($unicorn_bin, "-c#{ucfg.path}", "-l#{@addr}:#{@port}")
      end
    end

    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal String, results[0].class
    wait_master_ready(COMMON_TMP.path)
    wait_workers_ready(COMMON_TMP.path, HEAVY_WORKERS)
    bf = File.readlines(COMMON_TMP.path).grep(/\bbefore_fork: worker=/)
    assert_equal HEAVY_WORKERS, bf.size
    rotate = Tempfile.new('unicorn_rotate')

    File.rename(COMMON_TMP.path, rotate.path)
    Process.kill(:USR1, pid)

    wait_for_file(COMMON_TMP.path)
    assert File.exist?(COMMON_TMP.path), "#{COMMON_TMP.path} exists"
    # USR1 should've been passed to all workers
    tries = DEFAULT_TRIES
    log = File.readlines(rotate.path)
    while (tries -= 1) > 0 &&
          log.grep(/reopening logs\.\.\./).size < proc_total
      sleep DEFAULT_RES
      log = File.readlines(rotate.path)
    end
    assert_equal proc_total, log.grep(/reopening logs\.\.\./).size
    assert_equal 0, log.grep(/done reopening logs/).size

    tries = DEFAULT_TRIES
    log = File.readlines(COMMON_TMP.path)
    while (tries -= 1) > 0 && log.grep(/done reopening logs/).size < proc_total
      sleep DEFAULT_RES
      log = File.readlines(COMMON_TMP.path)
    end
    assert_equal proc_total, log.grep(/done reopening logs/).size
    assert_equal 0, log.grep(/reopening logs\.\.\./).size

    Process.kill(:QUIT, pid)
    pid, status = Process.waitpid2(pid)

    assert status.success?, "exited successfully"
  end

  def test_read_embedded_cli_switches
    File.open("config.ru", "wb") do |fp|
      fp.syswrite("#\\ -p #{@port} -o #{@addr}\n")
      fp.syswrite(HI)
    end
    pid = fork { redirect_test_io { exec($unicorn_bin) } }
    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal String, results[0].class
    assert_shutdown(pid)
  end

  def test_config_ru_alt_path
    config_path = "#{@tmpdir}/foo.ru"
    File.open(config_path, "wb") { |fp| fp.syswrite(HI) }
    pid = fork do
      redirect_test_io do
        Dir.chdir("/")
        exec($unicorn_bin, "-l#{@addr}:#{@port}", config_path)
      end
    end
    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal String, results[0].class
    assert_shutdown(pid)
  end

  def test_load_module
    libdir = "#{@tmpdir}/lib"
    FileUtils.mkpath([ libdir ])
    config_path = "#{libdir}/hello.rb"
    File.open(config_path, "wb") { |fp| fp.syswrite(HELLO) }
    pid = fork do
      redirect_test_io do
        Dir.chdir("/")
        exec($unicorn_bin, "-l#{@addr}:#{@port}", config_path)
      end
    end
    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal String, results[0].class
    assert_shutdown(pid)
  end

  def test_reexec
    File.open("config.ru", "wb") { |fp| fp.syswrite(HI) }
    pid_file = "#{@tmpdir}/test.pid"
    pid = fork do
      redirect_test_io do
        exec($unicorn_bin, "-l#{@addr}:#{@port}", "-P#{pid_file}")
      end
    end
    reexec_basic_test(pid, pid_file)
  end

  def test_reexec_alt_config
    config_file = "#{@tmpdir}/foo.ru"
    File.open(config_file, "wb") { |fp| fp.syswrite(HI) }
    pid_file = "#{@tmpdir}/test.pid"
    pid = fork do
      redirect_test_io do
        exec($unicorn_bin, "-l#{@addr}:#{@port}", "-P#{pid_file}", config_file)
      end
    end
    reexec_basic_test(pid, pid_file)
  end

  def test_socket_unlinked_restore
    results = nil
    sock = Tempfile.new('unicorn_test_sock')
    sock_path = sock.path
    @sockets << sock_path
    sock.close!
    ucfg = Tempfile.new('unicorn_test_config')
    ucfg.syswrite("listen \"#{sock_path}\"\n")

    File.open("config.ru", "wb") { |fp| fp.syswrite(HI) }
    pid = xfork { redirect_test_io { exec($unicorn_bin, "-c#{ucfg.path}") } }
    wait_for_file(sock_path)
    assert File.socket?(sock_path)

    sock = unix_socket(sock_path)
    sock.syswrite("GET / HTTP/1.0\r\n\r\n")
    results = sock.sysread(4096)

    assert_equal String, results.class
    File.unlink(sock_path)
    Process.kill(:HUP, pid)
    wait_for_file(sock_path)
    assert File.socket?(sock_path)

    sock = unix_socket(sock_path)
    sock.syswrite("GET / HTTP/1.0\r\n\r\n")
    results = sock.sysread(4096)

    assert_equal String, results.class
  end

  def test_unicorn_config_file
    pid_file = "#{@tmpdir}/test.pid"
    sock = Tempfile.new('unicorn_test_sock')
    sock_path = sock.path
    sock.close!
    @sockets << sock_path

    log = Tempfile.new('unicorn_test_log')
    ucfg = Tempfile.new('unicorn_test_config')
    ucfg.syswrite("listen \"#{sock_path}\"\n")
    ucfg.syswrite("pid \"#{pid_file}\"\n")
    ucfg.syswrite("logger Logger.new('#{log.path}')\n")
    ucfg.close

    File.open("config.ru", "wb") { |fp| fp.syswrite(HI) }
    pid = xfork do
      redirect_test_io do
        exec($unicorn_bin, "-l#{@addr}:#{@port}",
             "-P#{pid_file}", "-c#{ucfg.path}")
      end
    end
    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal String, results[0].class
    wait_master_ready(log.path)
    assert File.exist?(pid_file), "pid_file created"
    assert_equal pid, File.read(pid_file).to_i
    assert File.socket?(sock_path), "socket created"

    sock = unix_socket(sock_path)
    sock.syswrite("GET / HTTP/1.0\r\n\r\n")
    results = sock.sysread(4096)

    assert_equal String, results.class

    # try reloading the config
    sock = Tempfile.new('new_test_sock')
    new_sock_path = sock.path
    @sockets << new_sock_path
    sock.close!
    new_log = Tempfile.new('unicorn_test_log')
    new_log.sync = true
    assert_equal 0, new_log.size

    ucfg = File.open(ucfg.path, "wb")
    ucfg.syswrite("listen \"#{sock_path}\"\n")
    ucfg.syswrite("listen \"#{new_sock_path}\"\n")
    ucfg.syswrite("pid \"#{pid_file}\"\n")
    ucfg.syswrite("logger Logger.new('#{new_log.path}')\n")
    ucfg.close
    Process.kill(:HUP, pid)

    wait_for_file(new_sock_path)
    assert File.socket?(new_sock_path), "socket exists"
    @sockets.each do |path|
      sock = unix_socket(path)
      sock.syswrite("GET / HTTP/1.0\r\n\r\n")
      results = sock.sysread(4096)
      assert_equal String, results.class
    end

    assert_not_equal 0, new_log.size
    reexec_usr2_quit_test(pid, pid_file)
  end

  # we need to flock() something to prevent these tests from running
  def default_listen_lock(&block)
    fp = File.open(FLOCK_PATH, "rb")
    begin
      fp.flock(File::LOCK_EX)
      begin
        TCPServer.new(Unicorn::Const::DEFAULT_HOST,
                      Unicorn::Const::DEFAULT_PORT).close
      rescue Errno::EADDRINUSE, Errno::EACCES
        warn "can't bind to #{Unicorn::Const::DEFAULT_LISTEN}"
        return false
      end

      # unused_port should never take this, but we may run an environment
      # where tests are being run against older unicorns...
      lock_path = "#{Dir::tmpdir}/unicorn_test." \
                  "#{Unicorn::Const::DEFAULT_LISTEN}.lock"
      begin
        File.open(lock_path, File::WRONLY|File::CREAT|File::EXCL, 0600)
        yield
      rescue Errno::EEXIST
        lock_path = nil
        return false
      ensure
        File.unlink(lock_path) if lock_path
      end
    ensure
      fp.flock(File::LOCK_UN)
    end
  end

end if do_test

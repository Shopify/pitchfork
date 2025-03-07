# -*- encoding: binary -*-
# frozen_string_literal: true

# Copyright (c) 2005 Zed A. Shaw
# You can redistribute it and/or modify it under the same terms as Ruby 1.8 or
# the GPLv2+ (GPLv3+ preferred)
#
# Additional work donated by contributors.  See git history
# for more information.

STDIN.sync = STDOUT.sync = STDERR.sync = true # buffering makes debugging hard

# FIXME: move curl-dependent tests into t/
ENV['NO_PROXY'] ||= ENV['UNICORN_TEST_ADDR'] || '127.0.0.1'

# Some tests watch a log file or a pid file to spring up to check state
# Can't rely on inotify on non-Linux and logging to a pipe makes things
# more complicated
DEFAULT_TRIES = 100
DEFAULT_RES = 0.2

require 'net/http'
require 'digest/sha1'
require 'uri'
require 'stringio'
require 'pathname'
require 'tempfile'
require 'fileutils'
require 'logger'
require 'pitchfork'
require 'io/nonblock'
require 'rack/lint'

if ENV['DEBUG']
  require 'ruby-debug'
  Debugger.start
end

module Pitchfork
  class Test < Megatest::Test
    def before_setup
      Pitchfork::SharedMemory::PAGES.clear
      Pitchfork::SharedMemory.preallocate_pages(4)
    end

    private

    def redirect_test_io
      orig_err = STDERR.dup
      orig_out = STDOUT.dup
      rdr_pid = $$
      new_out = File.open("test_stdout.#$$.log", "a")
      new_err = File.open("test_stderr.#$$.log", "a")
      new_out.sync = new_err.sync = true

      if tail = ENV['TAIL'] # "tail -F" if GNU, "tail -f" otherwise
        require 'shellwords'
        cmd = tail.shellsplit
        cmd << new_out.path
        cmd << new_err.path
        pid = Process.spawn(*cmd, { 1 => 2, :pgroup => true })
        sleep 0.1 # wait for tail(1) to startup
      end
      STDERR.reopen(new_err)
      STDOUT.reopen(new_out)
      STDERR.sync = STDOUT.sync = true

      at_exit do
        if rdr_pid == $$
          File.unlink(new_out.path) rescue nil
          File.unlink(new_err.path) rescue nil
        end
      end

      begin
        yield
      ensure
        STDERR.reopen(orig_err)
        STDOUT.reopen(orig_out)
        Process.kill(:TERM, pid) if pid
      end
    end

    # which(1) exit codes cannot be trusted on some systems
    # We use UNIX shell utilities in some tests because we don't trust
    # ourselves to write Ruby 100% correctly :)
    def which(bin)
      ex = ENV['PATH'].split(/:/).detect do |x|
        x << "/#{bin}"
        File.executable?(x)
      end or warn "`#{bin}' not found in PATH=#{ENV['PATH']}"
      ex
    end

    # Either takes a string to do a get request against, or a tuple of [URI, HTTP] where
    # HTTP is some kind of Net::HTTP request object (POST, HEAD, etc.)
    def hit(uris)
      results = []
      uris.each do |u|
        res = nil

        if u.kind_of? String
          u = 'http://127.0.0.1:8080/' if u == 'http://0.0.0.0:8080/'
          res = Net::HTTP.get(URI.parse(u))
        else
          url = URI.parse(u[0])
          res = Net::HTTP.new(url.host, url.port).start {|h| h.request(u[1]) }
        end

        assert res != nil, "Didn't get a response: #{u}"
        results << res
      end

      return results
    end

    # unused_port provides an unused port on +addr+ usable for TCP that is
    # guaranteed to be unused across all pitchfork builds on that system.  It
    # prevents race conditions by using a lock file other pitchfork builds
    # will see.  This is required if you perform several builds in parallel
    # with a continuous integration system or run tests in parallel via
    # gmake.  This is NOT guaranteed to be race-free if you run other
    # processes that bind to random ports for testing (but the window
    # for a race condition is very small).  You may also set UNICORN_TEST_ADDR
    # to override the default test address (127.0.0.1).
    def unused_port(addr = '127.0.0.1')
      retries = 100
      base = 5000
      port = sock = nil
      begin
        begin
          port = base + rand(32768 - base)
          while port == Pitchfork::Const::DEFAULT_PORT
            port = base + rand(32768 - base)
          end

          sock = Socket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0)
          sock.bind(Socket.pack_sockaddr_in(port, addr))
          sock.listen(5)
        rescue Errno::EADDRINUSE, Errno::EACCES
          sock.close rescue nil
          retry if (retries -= 1) >= 0
        end

        # since we'll end up closing the random port we just got, there's a race
        # condition could allow the random port we just chose to reselect itself
        # when running tests in parallel with gmake.  Create a lock file while
        # we have the port here to ensure that does not happen .
        lock_path = "#{Dir::tmpdir}/pitchfork_test.#{addr}:#{port}.lock"
        File.open(lock_path, File::WRONLY|File::CREAT|File::EXCL, 0600).close
        at_exit { File.unlink(lock_path) rescue nil }
      rescue Errno::EEXIST
        sock.close rescue nil
        retry
      end
      sock.close rescue nil
      port
    end

    def try_require(lib)
      begin
        require lib
        true
      rescue LoadError
        false
      end
    end

    # sometimes the server may not come up right away
    def retry_hit(uris = [])
      tries = DEFAULT_TRIES
      begin
        hit(uris)
      rescue Errno::EINVAL, Errno::ECONNREFUSED => err
        if (tries -= 1) > 0
          sleep DEFAULT_RES
          retry
        end
        raise err
      end
    end

    def assert_shutdown(pid)
      wait_monitor_ready("test_stderr.#{pid}.log")
      Process.kill(:QUIT, pid)
      pid, status = Process.waitpid2(pid)
      assert status.success?, "exited successfully"
    end

    def wait_workers_ready(path, nr_workers)
      tries = DEFAULT_TRIES
      lines = []
      while (tries -= 1) > 0
        begin
          lines = File.readlines(path).grep(/worker=\d+.*ready/)
          lines.size == nr_workers and return
        rescue Errno::ENOENT
        end
        sleep DEFAULT_RES
      end
      raise "#{nr_workers} workers never became ready:" \
            "\n\t#{lines.join("\n\t")}\n"
    end

    def wait_monitor_ready(monitor_log)
      tries = DEFAULT_TRIES
      while (tries -= 1) > 0
        begin
          File.readlines(monitor_log).grep(/monitor process ready/)[0] and return
        rescue Errno::ENOENT
        end
        sleep DEFAULT_RES
      end
      raise "monitor process never became ready"
    end

    def wait_for_file(path)
      tries = DEFAULT_TRIES
      while (tries -= 1) > 0 && ! File.exist?(path)
        sleep DEFAULT_RES
      end
      assert File.exist?(path), "path=#{path} exists #{caller.inspect}"
    end

    def xfork(&block)
      fork do
        ObjectSpace.each_object(Tempfile) do |tmp|
          ObjectSpace.undefine_finalizer(tmp)
        end
        yield
      end
    end

    # can't waitpid on detached processes
    def wait_for_death(pid)
      tries = DEFAULT_TRIES
      while (tries -= 1) > 0
        begin
          Process.kill(0, pid)
          begin
            Process.waitpid(pid, Process::WNOHANG)
          rescue Errno::ECHILD
          end
          sleep(DEFAULT_RES)
        rescue Errno::ESRCH
          return
        end
      end
      raise "PID:#{pid} never died!"
    end

    def reset_sig_handlers
      %w(QUIT INT TERM USR2 HUP TTIN TTOU CHLD).each do |sig|
        trap(sig, "DEFAULT")
      end
    end

    def tcp_socket(*args)
      sock = TCPSocket.new(*args)
      sock.nonblock = false
      sock
    end

    def unix_socket(*args)
      sock = UNIXSocket.new(*args)
      sock.nonblock = false
      sock
    end
  end
end

# frozen_string_literal: true

require 'test_helper'

class TestInfo < Pitchfork::Test
  def test_close_all_ios_except_marked_ones
    if RUBY_VERSION < '3.2.3'
      assert_raises NoMethodError do
        Pitchfork::Info.close_all_ios!
      end
    else
      r, w = IO.pipe

      Pitchfork::Info.keep_io(w)

      pid = Process.fork do
        Pitchfork::Info.close_all_ios!

        w.write(Marshal.dump([
          $stdin.closed?,
          $stdout.closed?,
          $stderr.closed?,
          r.closed?,
          w.closed?
        ]))
        Process.exit!(0)
      end

      _, status = Process.wait2(pid)
      assert_predicate status, :success?

      info = Marshal.load(r)

      assert_equal([
        false, # $stdin
        false, # $stdout
        false, # $stderr
        true, # r
        false, # w
      ], info)
    end
  end

  def test_close_all_ios_catches_bad_file_descriptor_errors
    fake_socket_reopen_badf = Class.new(File) do
      def initialize
        super(File::NULL)
      end

      def is_a?(mod)
        super || mod == TCPSocket
      end

      def reopen(...)
        raise Errno::EBADF
      end
    end

    fake_file_close_ebadf = Class.new(File) do
      def initialize
        super(File::NULL)
      end

      def close
        raise Errno::EBADF
      end
    end

    @socket = fake_socket_reopen_badf.new
    @file = fake_file_close_ebadf.new

    Pitchfork::Info.close_all_ios!

    assert true
  end
end

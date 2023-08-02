# frozen_string_literal: true

require 'test_helper'

class TestInfo < Pitchfork::Test
  def test_close_all_ios_except_marked_ones
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

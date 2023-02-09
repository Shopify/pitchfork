require 'test_helper'

class TestSelectWaiter < Pitchfork::Test
  def test_select_timeout # n.b. this is level-triggered
    sw = Pitchfork::SelectWaiter.new
    IO.pipe do |r,w|
      sw.get_readers(ready = [], [r], 0)
      assert_equal [], ready
      w.syswrite '.'
      sw.get_readers(ready, [r], 1000)
      assert_equal [r], ready
      sw.get_readers(ready, [r], 0)
      assert_equal [r], ready
    end
  end

  def test_linux # ugh, also level-triggered, unlikely to change
    IO.pipe do |r,w|
      wtr = Pitchfork::Waiter.prep_readers([r])
      wtr.get_readers(ready = [], [r], 0)
      assert_equal [], ready
      w.syswrite '.'
      wtr.get_readers(ready = [], [r], 1000)
      assert_equal [r], ready
      wtr.get_readers(ready = [], [r], 1000)
      assert_equal [r], ready, 'still ready (level-triggered :<)'
      assert_nil wtr.close
    end
  rescue SystemCallError => e
    warn "#{e.message} (#{e.class})"
  end if Pitchfork.const_defined?(:Waiter)
end

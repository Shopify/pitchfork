require 'test_helper'

class TestFlock < Pitchfork::Test
  def setup
    @flock = Pitchfork::Flock.new("test")
  end

  def teardown
    @flock.unlink
  end

  def test_try_lock
    assert_equal true, @flock.try_lock
    assert_raises Pitchfork::Flock::Error do
      @flock.try_lock
    end
  end

  def test_unlock
    assert_raises Pitchfork::Flock::Error do
      @flock.unlock
    end
    assert_equal true, @flock.try_lock
    assert_equal true, @flock.unlock
  end

  def test_at_fork
    @flock.try_lock

    parent_rd, child_wr = IO.pipe
    child_rd, parent_wr = IO.pipe
    pid = fork do
      error = begin
        @flock.try_lock
      rescue => e
        e
      end
      child_wr.write(Marshal.dump(error))
      @flock.at_fork
      child_wr.write(Marshal.dump(@flock.try_lock))

      child_rd.read("next\n".bytesize)
      child_wr.write(Marshal.dump(@flock.try_lock))
      child_rd.read("next\n".bytesize) # block forever
    end

    error = Marshal.load(parent_rd)
    assert_instance_of Pitchfork::Flock::Error, error
    assert_match "trying to lock an already owned lock", error.message
    assert_equal false, Marshal.load(parent_rd)

    assert_equal true, @flock.unlock
    parent_wr.write("lock\n")
    assert_equal true, Marshal.load(parent_rd)
    assert_equal false, @flock.try_lock

    Process.kill('KILL', pid)
    Process.wait(pid)
    assert_equal true, @flock.try_lock
  end
end

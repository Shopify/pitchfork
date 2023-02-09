# -*- encoding: binary -*-

require 'test_helper'

class TestUtil < Pitchfork::Test
  EXPECT_FLAGS = File::WRONLY | File::APPEND

  def test_socketpair
    child, parent = Pitchfork.socketpair
    assert child
    assert parent
  ensure
    child.close
    parent.close
  end

  def test_pipe
    r, w = Pitchfork.pipe
    assert r
    assert w

    return if RUBY_PLATFORM !~ /linux/

    begin
      f_getpipe_sz = 1032
      IO.pipe do |a, b|
        a_sz = a.fcntl(f_getpipe_sz)
        b.fcntl(f_getpipe_sz)
        assert_kind_of Integer, a_sz
        r_sz = r.fcntl(f_getpipe_sz)
        assert_equal Raindrops::PAGE_SIZE, r_sz
        assert_operator a_sz, :>=, r_sz
      end
    rescue Errno::EINVAL
      # Linux <= 2.6.34
    end
  ensure
    w.close
    r.close
  end

  TestMessage = Pitchfork::Message.new(:text, :pipe)
  def test_message_socket
    child, parent = Pitchfork.socketpair
    child_pid = fork do
      parent.sendmsg('just text')
      read, write = Pitchfork.pipe
      message = TestMessage.new('rich message', write)
      parent.sendmsg(message)
      write.close
      read.wait_readable(1)
      status = read.read_nonblock(11)
      exit!(Integer(status))
    end

    child.wait(1)
    assert_equal 'just text', child.recvmsg_nonblock(exception: false)
    child.wait(1)
    message = child.recvmsg_nonblock(exception: false)
    assert_instance_of TestMessage, message
    assert_equal 'rich message', message.text
    assert_instance_of IO, message.pipe

    message.pipe.wait_writable(1)
    message.pipe.write_nonblock("42")
    _, status = Process.waitpid2(child_pid)
    assert_equal 42, status.exitstatus
  end
end

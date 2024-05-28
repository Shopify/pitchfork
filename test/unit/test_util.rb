# -*- encoding: binary -*-
# frozen_string_literal: true

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

  TestMessage = Pitchfork::Message.new(:text, :pipe)
  def test_message_socket
    child, parent = Pitchfork.socketpair
    child_pid = fork do
      parent.sendmsg('just text')
      read, write = IO.pipe
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

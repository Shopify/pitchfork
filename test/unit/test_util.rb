# -*- encoding: binary -*-
# frozen_string_literal: true

require 'test_helper'

module Pitchfork
  class TestUtil < Test
    EXPECT_FLAGS = File::WRONLY | File::APPEND

    def test_socketpair
      child, parent = Pitchfork.socketpair
      assert child
      assert parent
    ensure
      child.close
      parent.close
    end

    TestMessage = Message.new(:text, :pipe)
    ExtendedTestMessage = Message.new(:text, :pipe, :optional, :other_optional)
    ExtendedWorkerReady = Message.new(:nr, :pid, :optional)
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

    def test_missing_trailing_message_fields_default_to_nil
      receiver, sender = Pitchfork.socketpair
      pipe_reader, pipe_writer = IO.pipe
      payload = Marshal.dump([ExtendedTestMessage, "original", MessageSocket::FD.new(0)])

      sender.to_io.sendmsg(payload, 0, nil, Socket::AncillaryData.unix_rights(pipe_writer))
      assert receiver.wait(1)
      received = receiver.recvmsg_nonblock
      assert_instance_of ExtendedTestMessage, received
      assert_equal "original", received.text
      assert_nil received.optional
      assert_nil received.other_optional
      received.pipe.write_nonblock("x")
      assert_equal "x", pipe_reader.read_nonblock(1)

      sender.to_io.sendmsg(Marshal.dump([ExtendedWorkerReady, 7, 42]), 0)
      assert receiver.wait(1)
      ready = receiver.recvmsg_nonblock
      assert_instance_of ExtendedWorkerReady, ready
      assert_equal 7, ready.nr
      assert_equal 42, ready.pid
      assert_nil ready.optional
    ensure
      received&.pipe&.close
      receiver&.close
      sender&.close
      pipe_reader&.close
      pipe_writer&.close
    end

    def test_unknown_trailing_message_fields_are_ignored
      receiver, sender = Pitchfork.socketpair
      cases = [
        [Message::WorkerReady, [7, 42, "future", nil], [7, 42]],
        [Message::PromoteWorker, [3, "future"], [3]],
        [Message::MoldSpawned, [nil, 44, 1, 0, nil, 123.5, "future"], [nil, 44, 1, 0, nil, 123.5]],
      ]

      cases.each do |klass, fields, expected|
        sender.to_io.sendmsg(Marshal.dump([klass, *fields]), 0)
        assert receiver.wait(1)
        received = receiver.recvmsg_nonblock
        assert_instance_of klass, received
        assert_equal expected, received.to_a
      end
    ensure
      receiver&.close
      sender&.close
    end

    def test_ignored_message_fields_close_their_descriptors
      receiver, sender = Pitchfork.socketpair
      pipe_reader, pipe_writer = IO.pipe
      extra_reader, extra_writer = IO.pipe
      payload = Marshal.dump([
        Message::MoldSpawned, nil, 44, 1, 0, MessageSocket::FD.new(0),
        123.5, "future", MessageSocket::FD.new(1)
      ])

      rights = Socket::AncillaryData.unix_rights(pipe_writer, extra_writer)
      sender.to_io.sendmsg(payload, 0, nil, rights)
      extra_writer.close
      assert receiver.wait(1)
      received = receiver.recvmsg_nonblock
      assert_equal 123.5, received.spawned_at
      assert_equal 44, received.pid
      received.pipe.write_nonblock("x")
      assert_equal "x", pipe_reader.read_nonblock(1)
      assert extra_reader.wait_readable(1)
      assert_nil extra_reader.read_nonblock(1, exception: false)
    ensure
      received&.pipe&.close
      receiver&.close
      sender&.close
      pipe_reader&.close
      pipe_writer&.close
      extra_reader&.close
      extra_writer&.close unless extra_writer&.closed?
    end

    def test_mold_spawned_timestamp_round_trip
      receiver, sender = Pitchfork.socketpair
      pipe_reader, pipe_writer = IO.pipe
      message = Message::MoldSpawned.new(nil, 42, 1, 0, pipe_writer, 123.5)

      sender.sendmsg(message)
      assert receiver.wait(1)
      received = receiver.recvmsg_nonblock
      assert_instance_of Message::MoldSpawned, received
      assert_equal 123.5, received.spawned_at
      assert_equal 42, received.pid
      received.pipe.write_nonblock("x")
      assert_equal "x", pipe_reader.read_nonblock(1)
    ensure
      received&.pipe&.close
      receiver&.close
      sender&.close
      pipe_reader&.close
      pipe_writer&.close
    end
  end
end

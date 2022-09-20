# -*- encoding: binary -*-

# :stopdoc:
module Unicorn
  class MessageSocket
    unless respond_to?(:ruby2_keywords, true)
      class << self
        def ruby2_keywords(*args)
          args
        end
      end
    end

    FD = Struct.new(:index)

    def initialize(socket)
      @socket = socket
    end

    def to_io
      @socket
    end

    def wait(*args)
      @socket.wait(*args)
    end
    ruby2_keywords :wait

    def close_read
      @socket.close_read
    end

    def close_write
      @socket.close_write
    end

    def close
      @socket.close
    end

    def read_nonblock(*args)
      @socket.read_nonblock(*args)
    end
    ruby2_keywords :read_nonblock

    def write_nonblock(*args)
      @socket.write_nonblock(*args)
    end
    ruby2_keywords :write_nonblock

    def sendmsg(message)
      payload, ios = dump_message(message)
      @socket.sendmsg(
        payload,
        0,
        nil,
        *ios.map { |io| Socket::AncillaryData.unix_rights(io) },
      )
    end

    def sendmsg_nonblock(message, exception: true)
      payload, ios = dump_message(message)
      @socket.sendmsg_nonblock(
        payload,
        0,
        nil,
        *ios.map { |io| Socket::AncillaryData.unix_rights(io) },
        exception: exception,
      )
    end

    def recvmsg_nonblock(exception: true)
      case message = @socket.recvmsg_nonblock(scm_rights: true, exception: exception)
      when Array
        load_message(message)
      else
        message
      end
    end

    private

    MARSHAL_PREFIX = (Marshal::MAJOR_VERSION.chr << Marshal::MINOR_VERSION.chr).freeze

    def load_message(message)
      payload, _, _, data = message

      if payload.empty?
        # EOF: Ruby return an empty packet on closed connection
        # https://bugs.ruby-lang.org/issues/19012
        return nil
      end

      unless payload.start_with?(MARSHAL_PREFIX)
        return payload
      end

      klass, *args = Marshal.load(payload)
      args.map! do |arg|
        if arg.is_a?(FD)
          data.unix_rights.fetch(arg.index)
        else
          arg
        end
      end

      klass.new(*args)
    end

    def dump_message(message)
      return [message, []] unless message.is_a?(Message)

      args = message.to_a
      ios = args.select { |arg| arg.is_a?(IO) || arg.is_a?(MessageSocket) }

      io_index = 0
      args.map! do |arg|
        if arg.is_a?(IO) || arg.is_a?(MessageSocket)
          fd = FD.new(io_index)
          io_index += 1
          fd
        else
          arg
        end
      end

      [Marshal.dump([message.class, *args]), ios.map(&:to_io)]
    end
  end

  Message = Class.new(Struct)
  class Message
    WorkerSpawned = Message.new(:nr, :pid, :pipe)
    SoftKill = Message.new(:signum)
  end
end

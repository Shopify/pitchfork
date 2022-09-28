# -*- encoding: binary -*-
require 'etc'
require 'stringio'
require 'raindrops'
require 'io/wait'

begin
  require 'rack'
rescue LoadError
  warn 'rack not available, functionality reduced'
end

# :stopdoc:
# Pitchfork module containing all of the classes (include C extensions) for
# running a Pitchfork web server.  It contains a minimalist HTTP server with just
# enough functionality to service web application requests fast as possible.
# :startdoc:

# pitchfork exposes very little of an user-visible API and most of its
# internals are subject to change.  pitchfork is designed to host Rack
# applications, so applications should be written against the Rack SPEC
# and not pitchfork internals.
module Pitchfork

  # Raised inside TeeInput when a client closes the socket inside the
  # application dispatch.  This is always raised with an empty backtrace
  # since there is nothing in the application stack that is responsible
  # for client shutdowns/disconnects.  This exception is visible to Rack
  # applications unless PrereadInput middleware is loaded.  This
  # is a subclass of the standard EOFError class and applications should
  # not rescue it explicitly, but rescue EOFError instead.
  ClientShutdown = Class.new(EOFError)

  # :stopdoc:

  # This returns a lambda to pass in as the app, this does not "build" the
  # app The returned lambda will be called when it is
  # time to build the app.
  def self.builder(ru, op)
    # allow Configurator to parse cli switches embedded in the ru file
    op = Pitchfork::Configurator::RACKUP.merge!(:file => ru, :optparse => op)
    if ru =~ /\.ru$/ && !defined?(Rack::Builder)
      abort "rack and Rack::Builder must be available for processing #{ru}"
    end

    # always called after config file parsing, may be called after forking
    lambda do |_, server|
      inner_app = case ru
      when /\.ru$/
        raw = File.read(ru)
        raw.sub!(/^__END__\n.*/, '')
        eval("Rack::Builder.new {(\n#{raw}\n)}.to_app", TOPLEVEL_BINDING, ru)
      else
        require ru
        Object.const_get(File.basename(ru, '.rb').capitalize)
      end

      if $DEBUG
        require 'pp'
        pp({ :inner_app => inner_app })
      end

      return inner_app unless server.default_middleware

      middleware = { # order matters
        ContentLength: nil,
        Chunked: nil,
        CommonLogger: [ $stderr ],
        ShowExceptions: nil,
        Lint: nil,
        TempfileReaper: nil,
      }

      # return value, matches rackup defaults based on env
      # Pitchfork does not support persistent connections, but Rainbows!
      # and Zbatery both do.  Users accustomed to the Rack::Server default
      # middlewares will need ContentLength/Chunked middlewares.
      case ENV["RACK_ENV"]
      when "development"
      when "deployment"
        middleware.delete(:ShowExceptions)
        middleware.delete(:Lint)
      else
        return inner_app
      end
      Rack::Builder.new do
        middleware.each do |m, args|
          use(Rack.const_get(m), *args) if Rack.const_defined?(m)
        end
        run inner_app
      end.to_app
    end
  end

  # returns an array of strings representing TCP listen socket addresses
  # and Unix domain socket paths.  This is useful for use with
  # Raindrops::Middleware under Linux: https://yhbt.net/raindrops/
  def self.listener_names
    Pitchfork::HttpServer::LISTENERS.map do |io|
      Pitchfork::SocketHelper.sock_name(io)
    end + Pitchfork::HttpServer::NEW_LISTENERS
  end

  def self.log_error(logger, prefix, exc)
    message = exc.message
    message = message.dump if /[[:cntrl:]]/ =~ message
    logger.error "#{prefix}: #{message} (#{exc.class})"
    exc.backtrace.each { |line| logger.error(line) }
  end

  F_SETPIPE_SZ = 1031 if RUBY_PLATFORM =~ /linux/

  def self.pipe # :nodoc:
    IO.pipe.each do |io|
      # shrink pipes to minimize impact on /proc/sys/fs/pipe-user-pages-soft
      # limits.
      if defined?(F_SETPIPE_SZ)
        begin
          io.fcntl(F_SETPIPE_SZ, Raindrops::PAGE_SIZE)
        rescue Errno::EINVAL
          # old kernel
        rescue Errno::EPERM
          # resizes fail if Linux is close to the pipe limit for the user
          # or if the user does not have permissions to resize
        end
      end
    end
  end

  @socket_type = :SOCK_SEQPACKET
  def self.socketpair
    # TODO: Explore wether we want to shrink buffers or set any other socket option
    pair = UNIXSocket.socketpair(@socket_type).map { |s| MessageSocket.new(s) }
    pair[0].close_write
    pair[1].close_read
    pair
  rescue Errno::EPROTONOSUPPORT
    if @socket_type == :SOCK_SEQPACKET
      # macOS and very old linuxes don't support SOCK_SEQPACKET (SCTP).
      # In such case we can fallback to SOCK_STREAM (TCP)
      warn("SEQPACKET (SCTP) isn't supported, falling back to STREAM")
      @socket_type = :SOCK_STREAM
      retry
    else
      raise
    end
  end
  # :startdoc:
end
# :enddoc:

%w(
  const socket_helper stream_input tee_input mem_info children message http_request
  refork_condition mold_selector configurator tmpio util http_response worker http_server
).each do |s|
  require_relative "pitchfork/#{s}"
end

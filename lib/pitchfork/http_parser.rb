# frozen_string_literal: true
# :enddoc:
# no stable API here

module Pitchfork
  class HttpParser

    # default parameters we merge into the request env for Rack handlers
    DEFAULTS = {
      "rack.errors" => $stderr,
      "rack.multiprocess" => true,
      "rack.multithread" => false,
      "rack.run_once" => false,
      "rack.version" => [1, 2],
      "rack.hijack?" => true,
      "SCRIPT_NAME" => "",

      # this is not in the Rack spec, but some apps may rely on it
      "SERVER_SOFTWARE" => "Pitchfork #{Pitchfork::Const::UNICORN_VERSION}"
    }

    NULL_IO = StringIO.new.binmode

    # :stopdoc:
    HTTP_RESPONSE_START = [ 'HTTP', '/1.1 ' ]
    EMPTY_ARRAY = [].freeze
    @@input_class = Pitchfork::TeeInput
    @@check_client_connection = false

    def self.input_class
      @@input_class
    end

    def self.input_class=(klass)
      @@input_class = klass
    end

    def self.check_client_connection
      @@check_client_connection
    end

    def self.check_client_connection=(bool)
      @@check_client_connection = bool
    end

    # :startdoc:

    # Does the majority of the IO processing.  It has been written in
    # Ruby using about 8 different IO processing strategies.
    #
    # It is currently carefully constructed to make sure that it gets
    # the best possible performance for the common case: GET requests
    # that are fully complete after a single read(2)
    #
    # Anyone who thinks they can make it faster is more than welcome to
    # take a crack at it.
    #
    # returns an environment hash suitable for Rack if successful
    # This does minimal exception trapping and it is up to the caller
    # to handle any socket errors (e.g. user aborted upload).
    def read(socket)
      e = env

      # From https://www.ietf.org/rfc/rfc3875:
      # "Script authors should be aware that the REMOTE_ADDR and
      #  REMOTE_HOST meta-variables (see sections 4.1.8 and 4.1.9)
      #  may not identify the ultimate source of the request.  They
      #  identify the client for the immediate request to the server;
      #  that client may be a proxy, gateway, or other intermediary
      #  acting on behalf of the actual source client."
      address = socket.remote_address
      e['REMOTE_ADDR'] = if address.unix?
        "127.0.0.1"
      else
        address.ip_address
      end

      # short circuit the common case with small GET requests first
      socket.readpartial(16384, buf)
      if parse.nil?
        # Parser is not done, queue up more data to read and continue parsing
        # an Exception thrown from the parser will throw us out of the loop
        false until add_parse(socket.readpartial(16384))
      end

      check_client_connection(socket) if @@check_client_connection

      e['rack.input'] = 0 == content_length ?
                        NULL_IO : @@input_class.new(socket, self)

      # for Rack hijacking in Rack 1.5 and later
      e['pitchfork.socket'] = socket
      e['rack.hijack'] = self

      e.merge!(DEFAULTS)
    end

    # for rack.hijack, we respond to this method so no extra allocation
    # of a proc object
    def call
      hijacked!
      env['rack.hijack_io'] = env['pitchfork.socket']
    end

    def hijacked?
      env.include?('rack.hijack_io')
    end

    if Socket.const_defined?(:TCP_INFO) # Linux
      def check_client_connection(socket) # :nodoc:
        if TCPSocket === socket
          begin
            tcp_info = socket.getsockopt(Socket::IPPROTO_TCP, Socket::TCP_INFO)
          rescue IOError, SystemCallError
            return write_http_header(socket)
          end

          case tcp_info.data.unpack1("C")
          when 6, 7, 8, 9, 11 # TIME_WAIT, CLOSE, CLOSE_WAIT, LAST_ACK, CLOSING
            raise Errno::EPIPE, "client closed connection", EMPTY_ARRAY
          end
        else
          write_http_header(socket)
        end
      end
    else
      def check_client_connection(socket) # :nodoc:
        write_http_header(socket)
      end
    end

    def write_http_header(socket) # :nodoc:
      if headers?
        self.response_start_sent = true
        HTTP_RESPONSE_START.each { |c| socket.write(c) }
      end
    end

    # called by ext/pitchfork_http/pitchfork_http.rl via rb_funcall
    def self.is_chunked?(v) # :nodoc:
      vals = v.split(',')
      vals.each do |val|
        val.strip!
        val.downcase!
      end

      if vals.pop == 'chunked'
        return true unless vals.include?('chunked')
        raise Pitchfork::HttpParserError, 'double chunked', []
      end
      return false unless vals.include?('chunked')
      raise Pitchfork::HttpParserError, 'chunked not last', []
    end
  end
end

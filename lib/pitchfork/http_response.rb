# -*- encoding: binary -*-
# frozen_string_literal: true
# :enddoc:

module Pitchfork
  # Writes a Rack response to your client using the HTTP/1.1 specification.
  # You use it by simply doing:
  #
  #   status, headers, body = rack_app.call(env)
  #   http_response_write(socket, status, headers, body)
  #
  # Most header correctness (including Content-Length and Content-Type)
  # is the job of Rack, with the exception of the "Date" and "Status" header.
  module HttpResponse
    STATUS_CODES = defined?(Rack::Utils::HTTP_STATUS_CODES) ?
                   Rack::Utils::HTTP_STATUS_CODES : {}

    ILLEGAL_HEADER_VALUE = /[\x00-\x08\x0A-\x1F]/

    # internal API, code will always be common-enough-for-even-old-Rack
    def err_response(code, response_start_sent)
      "#{response_start_sent ? '' : 'HTTP/1.1 '}" \
        "#{code} #{STATUS_CODES[code]}\r\n\r\n"
    end

    def append_header(buf, key, value)
      case value
      when Array # Rack 3
        value.each do |v|
          next if ILLEGAL_HEADER_VALUE.match?(v)
          buf << "#{key}: #{v}\r\n"
        end
      when /\n/ # Rack 2
        # avoiding blank, key-only cookies with /\n+/
        value.split(/\n+/).each do |v|
          next if ILLEGAL_HEADER_VALUE.match?(v)
          buf << "#{key}: #{v}\r\n"
        end
      else
        buf << "#{key}: #{value}\r\n"
      end
    end

    # writes the rack_response to socket as an HTTP response
    def http_response_write(socket, status, headers, body,
                            req = Pitchfork::HttpParser.new)
      hijack = nil

      if headers
        code = status.to_i
        msg = STATUS_CODES[code]
        start = req.response_start_sent ? '' : 'HTTP/1.1 '
        buf = "#{start}#{msg ? %Q(#{code} #{msg}) : status}\r\n" \
              "Date: #{httpdate}\r\n" \
              "Connection: close\r\n".b
        headers.each do |key, value|
          case key
          when %r{\A(?:Date|Connection)\z}i
            next
          when "rack.hijack"
            # This should only be hit under Rack >= 1.5, as this was an illegal
            # key in Rack < 1.5
            hijack = value
          else
            append_header(buf, key, value)
          end
        end
        buf << "\r\n"
      end

      if hijack
        socket.write(buf) if buf
        req.hijacked!
        hijack.call(socket)
      elsif body.respond_to?(:each)
        # Combine the header block with the first body chunk into a single
        # write (backed by writev(2) when supported) to save a syscall on
        # the common case of a response with a single body chunk.
        #
        # `buf` itself (rather than a separate flag) is the "already sent"
        # sentinel: some bodies (e.g. ones that defer emitting via #close)
        # capture the block passed to #each and invoke it again later, so
        # the sentinel must be a value the closure observes being mutated,
        # not a value captured at closure-creation time.
        body.each do |chunk|
          if buf
            socket.write(buf, chunk)
            buf = nil
          else
            socket.write(chunk)
          end
        end
        if buf
          socket.write(buf)
          buf = nil
        end
      else
        socket.write(buf) if buf
        body.call(socket)
      end
    end
  end
end

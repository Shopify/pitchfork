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
        socket.write(buf << "\r\n")
      end

      if hijack
        req.hijacked!
        hijack.call(socket)
      else
        body.each { |chunk| socket.write(chunk) }
      end
    end
  end
end

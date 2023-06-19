# frozen_string_literal: true

require "rack"
if defined?(Rack::RELEASE) && Rack::RELEASE > "3"
  require "rack/constants"
  require "rack/utils"
end

module Pitchfork
  # Middleware that applies chunked transfer encoding to response bodies
  # when the response does not include a content-length header.
  #
  # This supports the trailer response header to allow the use of trailing
  # headers in the chunked encoding.  However, using this requires you manually
  # specify a response body that supports a +trailers+ method.  Example:
  #
  #   [200, { 'trailer' => 'expires'}, ["Hello", "World"]]
  #   # error raised
  #
  #   body = ["Hello", "World"]
  #   def body.trailers
  #     { 'expires' => Time.now.to_s }
  #   end
  #   [200, { 'trailer' => 'expires'}, body]
  #   # No exception raised
  class Chunked
    include Rack::Utils

    STATUS_WITH_NO_ENTITY_BODY = Hash[((100..199).to_a << 204 << 304).product([true])]

    # A body wrapper that emits chunked responses.
    class Body
      TERM = "\r\n"
      TAIL = "0#{TERM}"

      # Store the response body to be chunked.
      def initialize(body)
        @body = body
      end

      # For each element yielded by the response body, yield
      # the element in chunked encoding.
      def each(&block)
        term = TERM
        @body.each do |chunk|
          size = chunk.bytesize
          next if size == 0

          yield [size.to_s(16), term, chunk.b, term].join
        end
        yield TAIL
        yield_trailers(&block)
        yield term
      end

      # Close the response body if the response body supports it.
      def close
        @body.close if @body.respond_to?(:close)
      end

      private

      # Do nothing as this class does not support trailer headers.
      def yield_trailers
      end
    end

    # A body wrapper that emits chunked responses and also supports
    # sending Trailer headers.  Note that the response body provided to
    # initialize must have a +trailers+ method that returns a hash
    # of trailer headers, and the rack response itself should have a
    # Trailer header listing the headers that the +trailers+ method
    # will return.
    class TrailerBody < Body
      private

      # Yield strings for each trailer header.
      def yield_trailers
        @body.trailers.each_pair do |k, v|
          yield "#{k}: #{v}\r\n"
        end
      end
    end

    def initialize(app)
      @app = app
    end

    # Whether the HTTP version supports chunked encoding (HTTP 1.1 does).
    def chunkable_version?(ver)
      case ver
      # pre-HTTP/1.0 (informally "HTTP/0.9") HTTP requests did not have
      # a version (nor response headers)
      when 'HTTP/1.0', nil, 'HTTP/0.9'
        false
      else
        true
      end
    end

    # If the rack app returns a response that should have a body,
    # but does not have content-length or transfer-encoding headers,
    # modify the response to use chunked transfer-encoding.
    def call(env)
      status, headers, body = response = @app.call(env)

      if chunkable_version?(env[Rack::SERVER_PROTOCOL]) &&
         !STATUS_WITH_NO_ENTITY_BODY.key?(status.to_i) &&
         !headers[Rack::CONTENT_LENGTH] &&
         !headers[Rack::TRANSFER_ENCODING]

        headers[Rack::TRANSFER_ENCODING] = 'chunked'
        if headers['trailer']
          response[2] = TrailerBody.new(body)
        else
          response[2] = Body.new(body)
        end
      end

      response
    end
  end
end

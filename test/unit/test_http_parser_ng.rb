# -*- encoding: binary -*-
# frozen_string_literal: true

require 'test_helper'

module Pitchfork
  class HttpParserNgTest < Test

    def setup
      @parser = HttpParser.new
    end

    # RFC 7230 allows gzip/deflate/compress Transfer-Encoding,
    # but "chunked" must be last if used
    def test_is_chunked
      [ 'chunked,chunked', 'chunked,gzip', 'chunked,gzip,chunked' ].each do |x|
        assert_raises(HttpParserError) { HttpParser.is_chunked?(x) }
      end
      [ 'gzip, chunked', 'gzip,chunked', 'gzip ,chunked' ].each do |x|
        assert HttpParser.is_chunked?(x)
      end
      [ 'gzip', 'xhunked', 'xchunked' ].each do |x|
        assert !HttpParser.is_chunked?(x)
      end
    end

    def test_next_clear
      r = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
      @parser.buf << r
      @parser.parse
      @parser.response_start_sent = true
      assert @parser.keepalive?
      assert @parser.next?
      assert @parser.response_start_sent

      # persistent client makes another request:
      @parser.buf << r
      @parser.parse
      assert @parser.keepalive?
      assert @parser.next?
      assert_equal false, @parser.response_start_sent
    end

    def test_response_start_sent
      assert_equal false, @parser.response_start_sent, "default is false"
      @parser.response_start_sent = true
      assert_equal true, @parser.response_start_sent
      @parser.response_start_sent = false
      assert_equal false, @parser.response_start_sent
      @parser.response_start_sent = true
      @parser.clear
      assert_equal false, @parser.response_start_sent
    end

    def test_connection_TE
      @parser.buf << "GET / HTTP/1.1\r\nHost: example.com\r\nConnection: TE\r\n"
      @parser.buf << "TE: trailers\r\n\r\n"
      @parser.parse
      assert @parser.keepalive?
      assert @parser.next?
    end

    def test_keepalive_requests_with_next?
      req = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
      expect = {
        "SERVER_NAME" => "example.com",
        "HTTP_HOST" => "example.com",
        "rack.url_scheme" => "http",
        "REQUEST_PATH" => "/",
        "SERVER_PROTOCOL" => "HTTP/1.1",
        "PATH_INFO" => "/",
        "HTTP_VERSION" => "HTTP/1.1",
        "REQUEST_URI" => "/",
        "SERVER_PORT" => "80",
        "REQUEST_METHOD" => "GET",
        "QUERY_STRING" => ""
      }.freeze
      100.times do |nr|
        @parser.buf << req
        assert_equal expect, @parser.parse
        assert @parser.next?
      end
    end

    def test_default_keepalive_is_off
      assert ! @parser.keepalive?
      assert ! @parser.next?
      @parser.buf << "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
      @parser.parse
      assert @parser.keepalive?
      @parser.clear
      assert ! @parser.keepalive?
      assert ! @parser.next?
    end

    def test_identity_byte_headers
      req = @parser.env
      str = "PUT / HTTP/1.1\r\n".b
      str << "Content-Length: 123\r\n"
      str << "\r"
      hdr = @parser.buf
      str.each_byte { |byte|
        hdr << byte.chr
        assert_nil @parser.parse
      }
      hdr << "\n"
      assert_equal req.object_id, @parser.parse.object_id
      assert_equal '123', req['CONTENT_LENGTH']
      assert_equal 0, hdr.size
      assert ! @parser.keepalive?
      assert @parser.headers?
      assert_equal 123, @parser.content_length
      dst = "".b
      buf = '.' * 123
      @parser.filter_body(dst, buf)
      assert_equal '.' * 123, dst
      assert_equal "", buf
      assert @parser.keepalive?
    end

    def test_identity_step_headers
      req = @parser.env
      str = @parser.buf
      str << "PUT / HTTP/1.1\r\n"
      assert ! @parser.parse
      str << "Content-Length: 123\r\n"
      assert ! @parser.parse
      str << "\r\n"
      assert_equal req.object_id, @parser.parse.object_id
      assert_equal '123', req['CONTENT_LENGTH']
      assert_equal 0, str.size
      assert ! @parser.keepalive?
      assert @parser.headers?
      dst = "".b
      buf = '.' * 123
      @parser.filter_body(dst, buf)
      assert_equal '.' * 123, dst
      assert_equal "", buf
      assert @parser.keepalive?
    end

    def test_identity_oneshot_header
      req = @parser.env
      str = @parser.buf
      str << "PUT / HTTP/1.1\r\nContent-Length: 123\r\n\r\n"
      assert_equal req.object_id, @parser.parse.object_id
      assert_equal '123', req['CONTENT_LENGTH']
      assert_equal 0, str.size
      assert ! @parser.keepalive?
      assert @parser.headers?
      dst = "".b
      buf = '.' * 123
      @parser.filter_body(dst, buf)
      assert_equal '.' * 123, dst
      assert_equal "", buf
    end

    def test_identity_oneshot_header_with_body
      body = ('a' * 123).freeze
      req = @parser.env
      str = @parser.buf
      str << "PUT / HTTP/1.1\r\n" \
             "Content-Length: #{body.length}\r\n" \
             "\r\n#{body}"
      assert_equal req.object_id, @parser.parse.object_id
      assert_equal '123', req['CONTENT_LENGTH']
      assert_equal 123, str.size
      assert_equal body, str
      tmp = +''
      assert_nil @parser.filter_body(tmp, str)
      assert_equal 0, str.size
      assert_equal tmp, body
      assert_equal "", @parser.filter_body(tmp, str)
      assert @parser.keepalive?
    end

    def test_identity_oneshot_header_with_body_partial
      str = @parser.buf
      str << "PUT / HTTP/1.1\r\nContent-Length: 123\r\n\r\na"
      assert_equal Hash, @parser.parse.class
      assert_equal 1, str.size
      assert_equal 'a', str
      tmp = +''
      assert_nil @parser.filter_body(tmp, str)
      assert_equal "", str
      assert_equal "a", tmp
      str << ' ' * 122
      rv = @parser.filter_body(tmp, str)
      assert_equal 122, tmp.size
      assert_nil rv
      assert_equal "", str
      assert_equal str.object_id, @parser.filter_body(tmp, str).object_id
      assert @parser.keepalive?
    end

    def test_identity_oneshot_header_with_body_slop
      str = @parser.buf
      str << "PUT / HTTP/1.1\r\nContent-Length: 1\r\n\r\naG"
      assert_equal Hash, @parser.parse.class
      assert_equal 2, str.size
      assert_equal 'aG', str
      tmp = +''
      assert_nil @parser.filter_body(tmp, str)
      assert_equal "G", str
      assert_equal "G", @parser.filter_body(tmp, str)
      assert_equal 1, tmp.size
      assert_equal "a", tmp
      assert @parser.keepalive?
    end

    def test_chunked
      str = @parser.buf
      req = @parser.env
      str << "PUT / HTTP/1.1\r\ntransfer-Encoding: chunked\r\n\r\n"
      assert_equal req, @parser.parse, "msg=#{str}"
      assert_equal 0, str.size
      tmp = "".b
      assert_nil @parser.filter_body(tmp, str << "6")
      assert_equal 0, tmp.size
      assert_nil @parser.filter_body(tmp, str << "\r\n")
      assert_equal 0, str.size
      assert_equal 0, tmp.size
      tmp = "".b
      assert_nil @parser.filter_body(tmp, str << "..")
      assert_equal "..", tmp
      assert_nil @parser.filter_body(tmp, str << "abcd\r\n0\r\n")
      assert_equal "abcd", tmp
      assert_equal str.object_id, @parser.filter_body(tmp, str << "PUT").object_id
      assert_equal "PUT", str
      assert ! @parser.keepalive?
      str << "TY: FOO\r\n\r\n"
      assert_equal req, @parser.parse
      assert_nil req["HTTP_PUTTY"]
      assert_equal({ 'HTTP_PUTTY' => 'FOO' }, req['pitchfork.request_trailers'])
      assert @parser.keepalive?
    end

    def test_chunked_empty
      str = @parser.buf
      req = @parser.env
      str << "PUT / HTTP/1.1\r\ntransfer-Encoding: chunked\r\n\r\n"
      assert_equal req, @parser.parse, "msg=#{str}"
      assert_equal 0, str.size
      tmp = "".b
      assert_equal str, @parser.filter_body(tmp, str << "0\r\n\r\n")
      assert_equal "", tmp
      assert_equal req, @parser.parse
      assert_nil req['pitchfork.request_trailers']
    end

    def test_two_chunks
      str = @parser.buf
      str << "PUT / HTTP/1.1\r\ntransfer-Encoding: chunked\r\n\r\n"
      req = @parser.env
      assert_equal req, @parser.parse
      assert_equal 0, str.size
      tmp = "".b
      assert_nil @parser.filter_body(tmp, str << "6")
      assert_equal 0, tmp.size
      assert_nil @parser.filter_body(tmp, str << "\r\n")
      assert_equal "", str
      assert_equal 0, tmp.size
      tmp = "".b
      assert_nil @parser.filter_body(tmp, str << "..")
      assert_equal 2, tmp.size
      assert_equal "..", tmp
      assert_nil @parser.filter_body(tmp, str << "abcd\r\n1")
      assert_equal "abcd", tmp
      assert_nil @parser.filter_body(tmp, str << "\r")
      assert_equal "", tmp
      assert_nil @parser.filter_body(tmp, str << "\n")
      assert_equal "", tmp
      assert_nil @parser.filter_body(tmp, str << "z")
      assert_equal "z", tmp
      assert_nil @parser.filter_body(tmp, str << "\r\n")
      assert_nil @parser.filter_body(tmp, str << "0")
      assert_nil @parser.filter_body(tmp, str << "\r")
      rv = @parser.filter_body(tmp, str << "\nGET")
      assert_equal "GET", rv
      assert_equal str.object_id, rv.object_id
      assert ! @parser.keepalive?
    end

    def test_big_chunk
      str = @parser.buf
      str << "PUT / HTTP/1.1\r\ntransfer-Encoding: chunked\r\n\r\n" \
             "4000\r\nabcd"
      req = @parser.env
      assert_equal req, @parser.parse
      tmp = +''
      assert_nil @parser.filter_body(tmp, str)
      assert_equal '', str
      str << ' ' * 16300
      assert_nil @parser.filter_body(tmp, str)
      assert_equal '', str
      str << ' ' * 80
      assert_nil @parser.filter_body(tmp, str)
      assert_equal '', str
      assert ! @parser.body_eof?
      assert_equal "", @parser.filter_body(tmp, str << "\r\n0\r\n")
      assert_equal "", tmp
      assert @parser.body_eof?
      str << "\r\n"
      assert_equal req, @parser.parse
      assert_equal "", str
      assert @parser.body_eof?
      assert @parser.keepalive?
    end

    def test_two_chunks_oneshot
      str = @parser.buf
      req = @parser.env
      str << "PUT / HTTP/1.1\r\ntransfer-Encoding: chunked\r\n\r\n" \
             "1\r\na\r\n2\r\n..\r\n0\r\n"
      assert_equal req, @parser.parse
      tmp = +''
      assert_nil @parser.filter_body(tmp, str)
      assert_equal 'a..', tmp
      rv = @parser.filter_body(tmp, str)
      assert_equal rv.object_id, str.object_id
      assert ! @parser.keepalive?
    end

    def test_chunks_bytewise
      chunked = "10\r\nabcdefghijklmnop\r\n11\r\n0123456789abcdefg\r\n0\r\n"
      str = "PUT / HTTP/1.1\r\ntransfer-Encoding: chunked\r\n\r\n"
      buf = @parser.buf
      buf << str
      req = @parser.env
      assert_equal req, @parser.parse
      assert_equal "", buf
      tmp = +''
      body = +''
      str = chunked[0..-2]
      str.each_byte { |byte|
        assert_nil @parser.filter_body(tmp, buf << byte.chr)
        body << tmp
      }
      assert_equal 'abcdefghijklmnop0123456789abcdefg', body
      rv = @parser.filter_body(tmp, buf<< "\n")
      assert_equal rv.object_id, buf.object_id
      assert ! @parser.keepalive?
    end

    def test_trailers
      req = @parser.env
      str = @parser.buf
      str << "PUT / HTTP/1.1\r\n" \
             "Trailer: Content-MD5\r\n" \
             "transfer-Encoding: chunked\r\n\r\n" \
             "1\r\na\r\n2\r\n..\r\n0\r\n"
      assert_equal req, @parser.parse
      assert_equal 'Content-MD5', req['HTTP_TRAILER']
      assert_nil req['HTTP_CONTENT_MD5']
      assert_nil req['pitchfork.request_trailers']
      tmp = +''
      assert_nil @parser.filter_body(tmp, str)
      assert_equal 'a..', tmp
      md5_b64 = [ Digest::MD5.digest(tmp) ].pack('m').strip.freeze
      rv = @parser.filter_body(tmp, str)
      assert_equal rv.object_id, str.object_id
      assert_equal '', str
      md5_hdr = "Content-MD5: #{md5_b64}\r\n"
      str << md5_hdr
      assert_nil @parser.trailers(req, str)
      assert_nil req['HTTP_CONTENT_MD5']
      assert_equal md5_b64, req['pitchfork.request_trailers']['HTTP_CONTENT_MD5']
      assert_equal "CONTENT_MD5: #{md5_b64}\r\n", str
      str << "\r"
      assert_nil @parser.parse
      str << "\nGET / "
      assert_equal req, @parser.parse
      assert_equal "GET / ", str
      assert @parser.keepalive?
    end

    def test_trailers_slowly
      str = @parser.buf
      str << "PUT / HTTP/1.1\r\n" \
             "Trailer: Content-MD5\r\n" \
             "transfer-Encoding: chunked\r\n\r\n" \
             "1\r\na\r\n2\r\n..\r\n0\r\n"
      req = @parser.env
      assert_equal req, @parser.parse
      assert_equal 'Content-MD5', req['HTTP_TRAILER']
      assert_nil req['HTTP_CONTENT_MD5']
      assert_nil req['pitchfork.request_trailers']
      tmp = +''
      assert_nil @parser.filter_body(tmp, str)
      assert_equal 'a..', tmp
      md5_b64 = [ Digest::MD5.digest(tmp) ].pack('m').strip.freeze
      rv = @parser.filter_body(tmp, str)
      assert_equal rv.object_id, str.object_id
      assert_equal '', str
      assert_nil @parser.trailers(req, str)
      assert_nil req['pitchfork.request_trailers']
      md5_hdr = "Content-MD5: #{md5_b64}\r\n"
      md5_hdr.each_byte { |byte|
        str << byte.chr
        assert_nil @parser.trailers(req, str)
      }
      assert_nil req['HTTP_CONTENT_MD5']
      assert_equal md5_b64, req['pitchfork.request_trailers']['HTTP_CONTENT_MD5']
      assert_equal "CONTENT_MD5: #{md5_b64}\r\n", str
      str << "\r"
      assert_nil @parser.parse
      str << "\n"
      assert_equal req, @parser.parse
    end

    def test_max_chunk
      str = @parser.buf
      str << "PUT / HTTP/1.1\r\n" \
             "transfer-Encoding: chunked\r\n\r\n" \
             "#{HttpParser::CHUNK_MAX.to_s(16)}\r\na\r\n2\r\n..\r\n0\r\n"
      req = @parser.env
      assert_equal req, @parser.parse
      assert_nil @parser.content_length
      @parser.filter_body(''.b, str)
      assert ! @parser.keepalive?
    end

    def test_max_body
      n = HttpParser::LENGTH_MAX
      @parser.buf << "PUT / HTTP/1.1\r\nContent-Length: #{n}\r\n\r\n"
      req = @parser.env
      @parser.headers(req, @parser.buf)
      assert_equal n, req['CONTENT_LENGTH'].to_i
      assert ! @parser.keepalive?
    end

    def test_overflow_chunk
      n = HttpParser::CHUNK_MAX + 1
      str = @parser.buf
      req = @parser.env
      str << "PUT / HTTP/1.1\r\n" \
             "transfer-Encoding: chunked\r\n\r\n" \
             "#{n.to_s(16)}\r\na\r\n2\r\n..\r\n0\r\n"
      assert_equal req, @parser.parse
      assert_nil @parser.content_length
      2.times do
        assert_raises(HttpParserError) { @parser.filter_body(''.b, str) }
      end
    end

    def test_overflow_content_length
      n = HttpParser::LENGTH_MAX + 1
      @parser.buf << "PUT / HTTP/1.1\r\nContent-Length: #{n}\r\n\r\n"
      assert_raises(HttpParserError) { @parser.parse }
    end

    def test_bad_chunk
      @parser.buf << "PUT / HTTP/1.1\r\n" \
                     "transfer-Encoding: chunked\r\n\r\n" \
                     "#zzz\r\na\r\n2\r\n..\r\n0\r\n"
      req = @parser.env
      assert_equal req, @parser.parse
      assert_nil @parser.content_length
      assert_raises(HttpParserError) { @parser.filter_body("".b, @parser.buf) }
    end

    def test_bad_chunk_clears_destination
      ["#invalid\r\n", "3\r\nabc\r\n#invalid\r\n"].each do |body|
        @parser = HttpParser.new
        @parser.buf << "PUT / HTTP/1.1\r\ntransfer-Encoding: chunked\r\n\r\n#{body}"
        @parser.parse
        dst = 'previous body data' * 8

        assert_raises(HttpParserError) { @parser.filter_body(dst, @parser.buf) }
        assert_equal '', dst
      end
    end

    # The decoded length must be set before anything can allocate: GC
    # compaction re-embeds Strings and only copies their logical length.
    # Runs in a subprocess so GC.stress and GC.auto_compact can't leak.
    def test_filter_body_survives_gc_compaction
      skip 'GC auto-compaction is unavailable' unless GC.respond_to?(:auto_compact=)

      script = <<~'RUBY'
        require "pitchfork/pitchfork_http"
        begin
          GC.auto_compact = true
        rescue NotImplementedError
          puts "SKIP"
          exit
        end
        10.times do
          parser = Pitchfork::HttpParser.new
          parser.buf << "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
          parser.parse
          dst = "x" * 64 << "x" * 2048 # heap-allocated, reused for a short body
          src = String.new(capacity: 2048) << "20\r\n" << "A" * 32 << "\r\n"
          shared = src.dup # advancing a shared source has to allocate
          GC.stress = true
          begin
            parser.filter_body(dst, shared)
          ensure
            GC.stress = false
          end
          abort dst.inspect unless dst == "A" * 32
        end
        puts "OK"
      RUBY
      lib = File.expand_path('../../lib', __dir__)
      output = IO.popen([RbConfig.ruby, '-I', lib, '-e', script], err: [:child, :out], &:read)
      skip 'GC compaction is not supported' if output.include?('SKIP')
      assert $?.success?, output
      assert_includes output, 'OK'
    end

    def test_bad_content_length
      @parser.buf << "PUT / HTTP/1.1\r\nContent-Length: 7ff\r\n\r\n"
      assert_raises(HttpParserError) { @parser.parse }
    end

    def test_bad_trailers
      ["Content-Length: 5", "Transfer-Encoding: identity", "Trailer: X-Foo"].each do |field|
        parser = HttpParser.new
        str = parser.buf
        req = parser.env
        str << "PUT / HTTP/1.1\r\n" \
               "transfer-Encoding: chunked\r\n\r\n" \
               "1\r\na\r\n2\r\n..\r\n0\r\n"
        assert_equal req, parser.parse
        tmp = +''
        assert_nil parser.filter_body(tmp, str)
        assert_equal 'a..', tmp
        assert_equal '', str
        str << "#{field}\r\n\r\n"
        assert_raises(HttpParserError) { parser.parse }
        assert_nil req['pitchfork.request_trailers']
      end
    end

    def test_repeat_headers
      str = "PUT / HTTP/1.1\r\n" \
            "Trailer: Content-MD5\r\n" \
            "Trailer: Content-SHA1\r\n" \
            "transfer-Encoding: chunked\r\n\r\n" \
            "1\r\na\r\n2\r\n..\r\n0\r\n"
      req = @parser.env
      @parser.buf << str
      assert_equal req, @parser.parse
      assert_equal 'Content-MD5,Content-SHA1', req['HTTP_TRAILER']
      assert ! @parser.keepalive?
    end

    def test_parse_simple_request
      parser = HttpParser.new
      req = parser.env
      parser.buf << "GET /read-rfc1945-if-you-dont-believe-me\r\n"
      assert_equal req, parser.parse
      assert_equal '', parser.buf
      expect = {
        "SERVER_NAME"=>"localhost",
        "rack.url_scheme"=>"http",
        "REQUEST_PATH"=>"/read-rfc1945-if-you-dont-believe-me",
        "PATH_INFO"=>"/read-rfc1945-if-you-dont-believe-me",
        "REQUEST_URI"=>"/read-rfc1945-if-you-dont-believe-me",
        "SERVER_PORT"=>"80",
        "SERVER_PROTOCOL"=>"HTTP/0.9",
        "REQUEST_METHOD"=>"GET",
        "QUERY_STRING"=>""
      }
      assert_equal expect, req
      assert ! parser.headers?
    end

    def test_path_info_semicolon
      qs = "QUERY_STRING"
      pi = "PATH_INFO"
      req = {}
      str = "GET %s HTTP/1.1\r\nHost: example.com\r\n\r\n"
      {
        "/1;a=b?c=d&e=f" => { qs => "c=d&e=f", pi => "/1;a=b" },
        "/1?c=d&e=f" => { qs => "c=d&e=f", pi => "/1" },
        "/1;a=b" => { qs => "", pi => "/1;a=b" },
        "/1;a=b?" => { qs => "", pi => "/1;a=b" },
        "/1?a=b;c=d&e=f" => { qs => "a=b;c=d&e=f", pi => "/1" },
      }.each do |uri, expect|
        assert_equal req, @parser.headers(req.clear, str % [ uri ])
        req = req.dup
        @parser.clear
        assert_equal uri, req["REQUEST_URI"], "REQUEST_URI mismatch"
        assert_equal expect[qs], req[qs], "#{qs} mismatch"
        assert_equal expect[pi], req[pi], "#{pi} mismatch"
        uri = URI.parse("http://example.com#{uri}")
        assert_equal uri.query.to_s, req[qs], "#{qs} mismatch URI.parse disagrees"
        assert_equal uri.path, req[pi], "#{pi} mismatch URI.parse disagrees"
      end
    end

    def test_path_info_option_wildcard
      req = {}
      uri = "*"
      str = "OPTIONS %s HTTP/1.1\r\nHost: example.com\r\n\r\n"
      assert_equal req, @parser.headers(req, str % [ uri ])
      req = req.dup
      @parser.clear

      assert_equal uri, req["REQUEST_URI"], "REQUEST_URI mismatch"
      assert_equal "", req["QUERY_STRING"], "QUERY_STRING mismatch"
      assert_equal "*", req["PATH_INFO"], "PATH_INFO mismatch"
    end

    def test_path_info_semicolon_absolute
      qs = "QUERY_STRING"
      pi = "PATH_INFO"
      req = {}
      str = "GET http://example.com%s HTTP/1.1\r\nHost: www.example.com\r\n\r\n"
      {
        "/1;a=b?c=d&e=f" => { qs => "c=d&e=f", pi => "/1;a=b" },
        "/1?c=d&e=f" => { qs => "c=d&e=f", pi => "/1" },
        "/1;a=b" => { qs => "", pi => "/1;a=b" },
        "/1;a=b?" => { qs => "", pi => "/1;a=b" },
        "/1?a=b;c=d&e=f" => { qs => "a=b;c=d&e=f", pi => "/1" },
      }.each do |uri,expect|
        assert_equal req, @parser.headers(req.clear, str % [ uri ])
        req = req.dup
        @parser.clear
        assert_equal uri, req["REQUEST_URI"], "REQUEST_URI mismatch"
        assert_equal "example.com", req["HTTP_HOST"], "Host: mismatch"
        assert_equal expect[qs], req[qs], "#{qs} mismatch"
        assert_equal expect[pi], req[pi], "#{pi} mismatch"
      end
    end

    def test_reject_underscore_framing_headers
      headers = {
        "Content_Length" => ["1", "invalid Content-Length"],
        "CONTENT_LENGTH" => ["1", "invalid Content-Length"],
        "content_length" => ["", "invalid Content-Length"],
        "cOnTeNt_LeNgTh" => ["1", "invalid Content-Length"],
        "Transfer_Encoding" => ["chunked", "invalid Transfer-Encoding"],
        "TRANSFER_ENCODING" => ["chunked", "invalid Transfer-Encoding"],
        "transfer_encoding" => ["", "invalid Transfer-Encoding"],
        "tRaNsFeR_EnCoDiNg" => ["gzip", "invalid Transfer-Encoding"],
      }
      standard = ["Content-Length: 1", "Transfer-Encoding: chunked"]

      headers.each do |name, (value, message)|
        [[], standard].each do |other|
          [other + ["#{name}: #{value}"], ["#{name}: #{value}"] + other].each do |lines|
            @parser = HttpParser.new
            @parser.buf << "POST / HTTP/1.1\r\n#{lines.join("\r\n")}\r\n\r\n"
            error = assert_raises(HttpParserError) { @parser.parse }
            assert_equal message, error.message
          end
        end
      end
    end

    def test_reject_fragmented_underscore_framing_headers
      ["Content_Length", "Transfer_Encoding"].each do |name|
        (0..name.length).each do |split|
          @parser = HttpParser.new
          @parser.buf << "POST / HTTP/1.1\r\n#{name[0, split]}"
          assert_nil @parser.parse
          @parser.buf << "#{name[split..-1]}: 1\r\n\r\n"
          assert_raises(HttpParserError) { @parser.parse }
        end
      end
    end

    def test_reject_underscore_framing_headers_in_trailers
      ["Content_Length", "Transfer_Encoding"].each do |name|
        @parser = HttpParser.new
        @parser.buf << "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n"
        @parser.parse
        @parser.filter_body(+"", @parser.buf)
        @parser.buf << "#{name}: 1\r\n\r\n"
        assert_raises(HttpParserError) { @parser.parse }
      end
    end

    def test_underscore_headers_do_not_create_rack_keys
      baseline = HttpParser.new
      baseline.buf << "GET / HTTP/1.1\r\n\r\n"
      expected = baseline.parse

      @parser.buf << "GET / HTTP/1.1\r\n" \
                     "X_Forwarded_For: forged\r\n" \
                     "Content_Type: text/plain\r\n" \
                     "Content_Length_Extra: one\r\n" \
                     "Transfer_Encoding_Extra: two\r\n" \
                     "X_Custom-Header: three\r\n\r\n"
      env = @parser.parse
      assert_nil env["HTTP_X_FORWARDED_FOR"]
      assert_nil env["CONTENT_TYPE"]
      assert_nil env["HTTP_CONTENT_LENGTH_EXTRA"]
      assert_nil env["HTTP_TRANSFER_ENCODING_EXTRA"]
      assert_nil env["HTTP_X_CUSTOM_HEADER"]
      assert_equal expected, env
    end

    def test_underscore_headers_do_not_change_normal_headers
      normal = [
        "X-Forwarded-For: trusted",
        "Content-Type: text/plain",
        "X-Custom-Header: normal",
        "X-Custom-Header: second",
      ]
      ignored = [
        "X_Forwarded_For: forged",
        "Content_Type: text/forged",
        "X_Custom-Header: first",
        "x_custom-header: second",
        "X-Custom_Header: distinct",
        "X_Forwarded_Proto: https",
      ]
      baseline = HttpParser.new
      baseline.buf << "GET / HTTP/1.1\r\n#{normal.join("\r\n")}\r\n\r\n"
      expected = baseline.parse

      [normal + ignored, ignored + normal].each do |headers|
        @parser = HttpParser.new
        @parser.buf << "GET / HTTP/1.1\r\n#{headers.join("\r\n")}\r\n\r\n"
        env = @parser.parse
        assert_equal "trusted", env["HTTP_X_FORWARDED_FOR"]
        assert_equal "text/plain", env["CONTENT_TYPE"]
        assert_equal "normal,second", env["HTTP_X_CUSTOM_HEADER"]
        assert_equal "http", env["rack.url_scheme"]
        assert_nil env["HTTP_X_FORWARDED_PROTO"]
        assert_equal expected, env
      end
    end

    def test_ignored_underscore_headers_and_continuations_when_fragmented
      name = "X_Custom-Header"
      (0..name.length).each do |split|
        @parser = HttpParser.new
        @parser.buf << "GET / HTTP/1.1\r\nX-Custom-Header: normal\r\n#{name[0, split]}"
        assert_nil @parser.parse
        @parser.buf << "#{name[split..-1]}: forged\r\n\tinjected\r\n"
        assert_nil @parser.parse
        @parser.buf << "X-Custom-Header: after\r\n\tkept\r\n\r\n"
        env = @parser.parse
        assert_equal "normal,after kept", env["HTTP_X_CUSTOM_HEADER"]
      end
    end

    def test_ignored_underscore_trailer_continuations_do_not_poison_valid_trailers
      @parser.buf << "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n"
      env = @parser.parse
      @parser.filter_body(+"", @parser.buf)
      @parser.buf << "X_Custom-Header: forged\r\n\tinjected\r\n" \
                     "Only_Trailer: ignored\r\n" \
                     "X-Custom-Header: trailer\r\n\tkept\r\n\r\n"
      @parser.parse
      assert_nil env["HTTP_X_CUSTOM_HEADER"]
      assert_nil env["HTTP_ONLY_TRAILER"]
      assert_equal({"HTTP_X_CUSTOM_HEADER" => "trailer kept"}, env["pitchfork.request_trailers"])
    end

    def test_ignored_underscore_header_name_length_limit
      name = "X_" + "a" * 254
      @parser.buf << "GET / HTTP/1.1\r\n#{name}: value\r\n\r\n"
      assert_nil @parser.parse["HTTP_#{name.upcase}"]

      @parser = HttpParser.new
      @parser.buf << "GET / HTTP/1.1\r\n#{name}a: value\r\n\r\n"
      assert_raises(HttpParserError) { @parser.parse }
    end

    def test_negative_content_length
      req = {}
      str = "PUT / HTTP/1.1\r\n" \
            "Content-Length: -1\r\n" \
            "\r\n"
      assert_raises(HttpParserError) do
        @parser.headers(req, str)
      end
    end

    def test_invalid_content_length
      req = {}
      str = "PUT / HTTP/1.1\r\n" \
            "Content-Length: zzzzz\r\n" \
            "\r\n"
      assert_raises(HttpParserError) do
        @parser.headers(req, str)
      end
    end

    def test_duplicate_content_length
      str = "PUT / HTTP/1.1\r\n" \
            "Content-Length: 1\r\n" \
            "Content-Length: 9\r\n" \
            "\r\n"
      assert_raises(HttpParserError) { @parser.headers({}, str) }
    end

    def test_chunked_overrides_content_length
      order = [ 'Transfer-Encoding: chunked', 'Content-Length: 666' ]
      %w(a b).each do |x|
        str = +"PUT /#{x} HTTP/1.1\r\n" \
              "#{order.join("\r\n")}" \
              "\r\n\r\na\r\nhelloworld\r\n0\r\n\r\n"
        order.reverse!
        env = @parser.headers({}, str)
        assert_nil @parser.content_length
        assert_equal 'chunked', env['HTTP_TRANSFER_ENCODING']
        assert_equal '666', env['CONTENT_LENGTH'],
          'Content-Length logged so the app can log a possible client bug/attack'
        @parser.filter_body(dst = ''.b, str)
        assert_equal 'helloworld', dst
        @parser.parse # handle the non-existent trailer
        assert @parser.next?
      end
    end

    def test_chunked_order_good
      str = "PUT /x HTTP/1.1\r\n" \
            "Transfer-Encoding: gzip\r\n" \
            "Transfer-Encoding: chunked\r\n" \
            "\r\n".b
      env = @parser.headers({}, str)
      assert_equal 'gzip,chunked', env['HTTP_TRANSFER_ENCODING']
      assert_nil @parser.content_length

      @parser.clear
      str = "PUT /x HTTP/1.1\r\n" \
            "Transfer-Encoding: gzip, chunked\r\n" \
            "\r\n".b
      env = @parser.headers({}, str)
      assert_equal 'gzip, chunked', env['HTTP_TRANSFER_ENCODING']
      assert_nil @parser.content_length
    end

    def test_chunked_order_bad
      str = "PUT /x HTTP/1.1\r\n" \
            "Transfer-Encoding: chunked\r\n" \
            "Transfer-Encoding: gzip\r\n" \
            "\r\n"
      assert_raises(HttpParserError) { @parser.headers({}, str) }
    end

    def test_double_chunked
      str = "PUT /x HTTP/1.1\r\n" \
            "Transfer-Encoding: chunked\r\n" \
            "Transfer-Encoding: chunked\r\n" \
            "\r\n"
      assert_raises(HttpParserError) { @parser.headers({}, str) }

      @parser.clear
      str = "PUT /x HTTP/1.1\r\n" \
            "Transfer-Encoding: chunked,chunked\r\n" \
            "\r\n"
      assert_raises(HttpParserError) { @parser.headers({}, str) }
    end

    def test_backtrace_is_empty
      begin
        @parser.headers({}, "AAADFSFDSFD\r\n\r\n")
        assert false, "should never get here line:#{__LINE__}"
      rescue HttpParserError => e
        assert_equal [], e.backtrace
        return
      end
      assert false, "should never get here line:#{__LINE__}"
    end

    def test_ignore_version_header
      @parser.buf << "GET / HTTP/1.1\r\nVersion: hello\r\n\r\n"
      req = @parser.env
      assert_equal req, @parser.parse
      assert_equal '', @parser.buf
      expect = {
        "SERVER_NAME" => "localhost",
        "rack.url_scheme" => "http",
        "REQUEST_PATH" => "/",
        "SERVER_PROTOCOL" => "HTTP/1.1",
        "PATH_INFO" => "/",
        "HTTP_VERSION" => "HTTP/1.1",
        "REQUEST_URI" => "/",
        "SERVER_PORT" => "80",
        "REQUEST_METHOD" => "GET",
        "QUERY_STRING" => ""
      }
      assert_equal expect, req
    end

    def test_pipelined_requests
      host = "example.com".b
      expect = {
        "HTTP_HOST" => host,
        "SERVER_NAME" => host,
        "REQUEST_PATH" => "/",
        "rack.url_scheme" => "http",
        "SERVER_PROTOCOL" => "HTTP/1.1",
        "PATH_INFO" => "/",
        "HTTP_VERSION" => "HTTP/1.1",
        "REQUEST_URI" => "/",
        "SERVER_PORT" => "80",
        "REQUEST_METHOD" => "GET",
        "QUERY_STRING" => ""
      }
      req1 = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
      req2 = "GET / HTTP/1.1\r\nHost: www.example.com\r\n\r\n"
      @parser.buf << (req1 + req2)
      env1 = @parser.parse.dup
      assert_equal expect, env1
      assert_equal req2, @parser.buf
      assert ! @parser.env.empty?
      assert @parser.next?
      assert @parser.keepalive?
      assert @parser.headers?
      assert_equal expect, @parser.env
      env2 = @parser.parse.dup
      host.replace "www.example.com"
      assert_equal "www.example.com", expect["HTTP_HOST"]
      assert_equal "www.example.com", expect["SERVER_NAME"]
      assert_equal expect, env2
      assert_equal "", @parser.buf
    end
  end
end

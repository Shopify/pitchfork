# frozen_string_literal: true

require 'test_helper'

module Pitchfork
  class ChunkedTest < Test
    def test_trailers_cannot_inject_headers
      output = chunked_output(
        "x-before" => "ok",
        "x-invalid" => "value\r\nx-injected: yes",
        "x-invalid\r\nx-injected" => "yes",
        "x-after" => "ok"
      )

      assert_equal "5\r\nhello\r\n0\r\nx-before: ok\r\nx-after: ok\r\n\r\n", output
    end

    def test_trailers_reject_forbidden_control_characters
      controls = (0..31).reject { |byte| byte == 9 } + [127]
      controls.each do |byte|
        control = byte.chr
        output = chunked_output(
          "x-invalid#{control}name" => "value",
          "x-invalid-value" => "bad#{control}value",
          "x-valid" => "ok\tvalue"
        )

        assert_equal "5\r\nhello\r\n0\r\nx-valid: ok\tvalue\r\n\r\n", output, "control byte #{byte}"
      end
    end

    def test_trailers_validate_the_serialized_value
      value = Object.new
      def value.to_s
        "value\r\nx-injected: yes"
      end

      assert_equal "5\r\nhello\r\n0\r\nvalid: 123\r\n\r\n", chunked_output(:valid => 123, "x-invalid" => value)
    end

    # obs-text (0x80-0xFF) is valid in field values whatever the String's
    # encoding tag says.
    def test_trailers_allow_high_bytes_with_any_encoding
      [
        "\xFF".dup.force_encoding(Encoding::UTF_8).freeze,
        "\xFF".b,
        "\xC3\xA9".dup.force_encoding(Encoding::UTF_8),
      ].each do |value|
        output = chunked_output("x-meta" => value)
        assert_equal "5\r\nhello\r\n0\r\nx-meta: #{value.b}\r\n\r\n".b, output, value.inspect
      end
    end

    def test_trailers_do_not_change_the_application_strings
      value = "\xFF".dup.force_encoding(Encoding::UTF_8)
      chunked_output("x-meta" => value)
      assert_equal Encoding::UTF_8, value.encoding
    end

    def test_trailers_with_invalid_encoding_cannot_inject_headers
      value = Object.new
      def value.to_s
        "\xFF\r\nx-injected: yes".dup.force_encoding(Encoding::UTF_8)
      end

      output = chunked_output(
        "x-value" => "\xFF\r\nx-injected: yes".dup.force_encoding(Encoding::UTF_8),
        "x-\xFF\r\nx-injected".dup.force_encoding(Encoding::UTF_8) => "yes",
        "x-to-s" => value,
        "x-control" => "\xFF\x7F".dup.force_encoding(Encoding::UTF_8),
        "x-valid" => "\xFF\tok".dup.force_encoding(Encoding::UTF_8)
      )
      assert_equal "5\r\nhello\r\n0\r\nx-valid: \xFF\tok\r\n\r\n".b, output
    end

    private

    def chunked_output(trailers)
      response_body = ["hello"]
      response_body.define_singleton_method(:trailers) { trailers }
      app = ->(_) { [200, { "trailer" => "x-valid" }, response_body] }
      _, _, body = Chunked.new(app).call("SERVER_PROTOCOL" => "HTTP/1.1")
      output = ''.b
      body.each { |chunk| output << chunk }
      output
    end
  end
end

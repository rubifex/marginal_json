# frozen_string_literal: true

require_relative "test_helper"

class ParserTest < Minitest::Test
  def test_json_values_and_byte_ranges
    text = '{"日本語":{"emoji":"🙂","value":[1,true,false,null,-1.25e2]}}'
    doc = Kochab.parse(text, strict: true)
    assert_equal JSON.parse(text), doc.value
    assert doc.valid?
    path = ["日本語", "emoji"]
    assert_equal '"🙂"', text.byteslice(doc.range_of(path))
    assert_equal '"emoji"', text.byteslice(doc.key_range_of(path))
    assert_equal path, doc.path_at(doc.range_of(path).begin + 1)
    assert_equal :string, doc.node_at(doc.range_of(path).begin).kind
    assert_nil doc.node_at(text.bytesize)
  end

  def test_comments_bom_trailing_commas_and_newlines
    text = "\uFEFF{\r\n // size\r\n \"font\": 14, // inline\r\n \"theme\": \"dark\",\r\n}"
    doc = Kochab.parse(text)
    assert doc.valid?, doc.errors.inspect
    assert_equal({"font" => 14, "theme" => "dark"}, doc.value)
    assert_equal "// size", doc.root.children.first.leading_comments.first.text
    assert_equal "// inline", doc.root.children.first.children.first.trailing_comment.text
    refute Kochab.parse(text, trailing_commas: false).valid?
    assert_raises(Kochab::ParseError) { Kochab.parse(text, strict: true) }
  end

  def test_recovery_and_duplicate_warning
    doc = Kochab.parse('{"a" 1, "b": , "c": 3, "a": 2}')
    assert_equal({"a" => 2, "b" => nil, "c" => 3}, doc.value)
    assert_includes doc.errors.map(&:code), :expected_colon
    assert_includes doc.errors.map(&:code), :expected_value
    assert_includes doc.errors.map(&:code), :duplicate_key
    duplicate = Kochab.parse('{"a":1,"a":2}', strict: true)
    assert duplicate.valid?
    assert_equal 2, duplicate.value["a"]
  end

  def test_nonfinite_is_opt_in_and_json5_is_rejected
    refute Kochab.parse('[NaN,Infinity,-Infinity]').valid?
    doc = Kochab.parse('[NaN,Infinity,-Infinity]', allow_nan: true)
    assert doc.valid?
    assert doc.value.first.nan?
    assert_equal [Float::INFINITY, -Float::INFINITY], doc.value.last(2)
    assert_raises(Kochab::ParseError) { Kochab.parse('[NaN]', strict: true, allow_nan: true) }
    ["{a:1}", "{'a':1}", '[0x1]', '[01]', '[1.]', '[.1]', '[+1]'].each do |source|
      refute Kochab.parse(source).valid?, source
    end
  end

  def test_line_and_utf16_position_roundtrip
    doc = Kochab.parse("[\r\n \"あ🙂\",\r 1,\n 2]")
    assert_equal [1, 5], doc.utf16_position_at(12)
    assert_equal 12, doc.offset_at_utf16_position(1, 5)
    assert_raises(RangeError) { doc.offset_at_utf16_position(1, 4) }
    assert_raises(RangeError) { doc.utf16_position_at(7) }
    assert_raises(RangeError) { doc.offset_at_utf16_position(20, 0) }
    assert_raises(RangeError) { doc.offset_at_utf16_position(1, 100) }
  end

  def test_depth_is_bounded_without_stack_overflow
    doc = Kochab.parse('[' * 10_000 + '0' + ']' * 10_000)
    assert_includes doc.errors.map(&:code), :depth_limit
  end

  def test_unfinished_final_escape_and_invalid_utf8_positions
    source = '"unfinished' + "\\"
    doc = Kochab.parse(source)
    assert_equal 0...source.bytesize, doc.root.range
    assert_equal "unfinished", doc.value
    invalid = Kochab.parse("\xff".b)
    assert_raises(EncodingError) { invalid.utf16_position_at(0) }
    assert_raises(EncodingError) { invalid.offset_at_utf16_position(0, 0) }
  end

  def test_invalid_string_escapes_are_diagnosed_in_keys_and_values
    ['\\a', '\\x00', '\\🌀', '\\UA66D', '\\uD800\\uD800\\x', '\\u12', '\\uXXXX', '\\u12G4'].each do |escape|
      literal = '"' + escape + '"'
      ["{\"あ\": #{literal}, \"tail\": true}", "{#{literal}: 1, \"tail\": true}"].each do |source|
        error = assert_raises(Kochab::ParseError, source) { Kochab.parse(source, strict: true) }
        doc = Kochab.parse(source)
        refute doc.valid?, source
        assert_equal true, doc.value["tail"]
        diagnostic = doc.errors.find { |entry| entry.code == :invalid_string }
        refute_nil diagnostic, source
        assert_equal literal, source.byteslice(diagnostic.range)
        assert_equal :error, diagnostic.severity
        assert_equal doc.errors.map(&:code), error.errors.map(&:code)
      end
    end
  end

  def test_all_json_escapes_decode_without_rejecting_escaped_backslashes
    literal = <<~'JSON'.strip
      "\"\\\/\b\f\n\r\t\u0041\uD83D\uDE42\\x\\uXXXX"
    JSON
    expected = "\"\\/\b\f\n\r\tA🙂\\x\\uXXXX"
    source = "{#{literal}: #{literal}}"
    doc = Kochab.parse(source, strict: true)
    assert doc.valid?
    assert_equal({expected => expected}, doc.value)
  end
end

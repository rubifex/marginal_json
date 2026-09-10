# frozen_string_literal: true

require_relative "test_helper"

class EditingTest < Minitest::Test
  def test_set_changes_only_the_value_bytes
    source = "\uFEFF{\r\n\t// keep あ🙂\r\n\t\"editor\" : { /* old */ \"size\" : 12 /* units */ },\r\n} // keep\r\n"
    doc = Kochab.parse(source)
    edit = doc.set(["editor", "size"], 14).fetch(0)
    assert_equal "12", source.byteslice(edit.offset, edit.length)
    updated = Kochab.apply(source, [edit])
    assert_equal source.sub("12", "14"), updated
    assert_equal 14, Kochab.parse(updated).value.dig("editor", "size")
    assert_equal 12, doc.value.dig("editor", "size")
    assert_equal source, doc.text
  end

  def test_insert_preserves_all_existing_bytes
    sources = ['{}', '{ }', '{"a":1}', '{"a":1,}', '{"a":1 /* keep */}',
      "{\n}", "{\n // keep\n}", "{\n  \"a\":1 // keep\n}", "{\n  \"a\":1}",
      "{\r\n\t\"a\":1, // keep\r\n}", '{/* keep */}']
    sources.each do |source|
      doc = Kochab.parse(source)
      edits = doc.insert(["日本語"], "🙂")
      assert edits.all? { |edit| edit.length.zero? }
      updated = Kochab.apply(source, edits)
      result = Kochab.parse(updated)
      assert result.valid?, "#{updated.inspect}: #{result.errors.inspect}"
      assert_equal doc.value.merge("日本語" => "🙂"), result.value
      assert_equal doc.comments.map(&:text), result.comments.map(&:text)
    end
  end

  def test_insert_after_preserves_leading_comments
    source = "{\n  \"a\": 1,\n  // about b\n  \"b\": 2\n}"
    doc = Kochab.parse(source)
    result = Kochab.parse(Kochab.apply(source, doc.insert(["c"], 3, after: "a")))
    assert result.valid?, result.text
    assert_equal %w[a c b], result.value.keys
    assert_equal "// about b", result.root.children.last.leading_comments.first.text
  end

  def test_remove_members_preserves_comments_and_whitespace
    source = "{\n // a\n \"a\":1, /* b */ \"b\":2, // c\n \"c\":3,\n}"
    %w[a b c].each do |key|
      doc = Kochab.parse(source)
      edits = doc.remove([key])
      result = Kochab.parse(Kochab.apply(source, edits))
      assert result.valid?, result.text
      assert_equal doc.value.reject { |name, _| name == key }, result.value
      assert_equal doc.comments.map(&:text), result.comments.map(&:text)
    end
    duplicate = Kochab.parse('{"a":1,"b":0,"a":2}')
    assert_equal({"b" => 0}, Kochab.parse(Kochab.apply(duplicate.text, duplicate.remove(["a"]))).value)
    duplicate = Kochab.parse('{"a":1,"a":2}')
    assert_equal({}, Kochab.parse(Kochab.apply(duplicate.text, duplicate.remove(["a"]))).value)
    assert_empty duplicate.remove(["missing"])
  end

  def test_array_edits_match_ruby_array_operations
    5.times do |index|
      source = '[0, /* one */ 1, 2, 3,]'
      doc = Kochab.parse(source)
      updated = Kochab.apply(source, doc.insert([index], {"あ" => true}))
      result = Kochab.parse(updated)
      assert result.valid?, updated
      assert_equal [0, 1, 2, 3].insert(index, {"あ" => true}), result.value
      next if index == 4

      result = Kochab.parse(Kochab.apply(source, doc.remove([index])))
      assert result.valid?, result.text
      expected = [0, 1, 2, 3]
      expected.delete_at(index)
      assert_equal expected, result.value
    end
    empty = Kochab.parse('[]')
    assert_equal '[1]', Kochab.apply('[]', empty.insert([0], 1))
  end

  def test_apply_validates_overlaps_bounds_and_utf8_boundaries
    edit = ->(offset, length, text) { Kochab::TextEdit.new(offset: offset, length: length, text: text) }
    assert_raises(ArgumentError) { Kochab.apply('abcd', [edit.call(0, 3, ''), edit.call(2, 1, '')]) }
    assert_raises(ArgumentError) { Kochab.apply('a', [edit.call(-1, 1, '')]) }
    assert_raises(ArgumentError) { Kochab.apply('a', [edit.call(0, 2, '')]) }
    assert_raises(ArgumentError) { Kochab.apply('🙂', [edit.call(1, 1, '')]) }
    assert_equal 'a12b', Kochab.apply('ab', [edit.call(1, 0, '1'), edit.call(1, 0, '2')])
    assert_equal 'x', Kochab.apply('🙂', [edit.call(0, 4, 'x')])
  end

  def test_editing_rejects_invalid_paths_and_unsafe_values
    doc = Kochab.parse('{"a":[]}')
    assert_raises(KeyError) { doc.set(["missing", "value"], 1) }
    assert_raises(TypeError) { doc.set([:a], 1) }
    assert_raises(ArgumentError) { doc.insert(["a"], 1) }
    assert_raises(IndexError) { doc.insert(["a", 1], 1) }
    assert_raises(JSON::GeneratorError) { doc.set(["a"], Float::NAN) }
    assert_raises(Kochab::ParseError) { Kochab.parse('{').insert(["a"], 1) }
  end

  def test_format_preserves_comment_tokens_values_and_blank_line_budget
    source = "{\r\n\r\n\r\n// leading\r\n\"a\": [1,2,], /* middle */\r\n\"b\":{\"日本語\": \"🙂\"} // trailing\r\n}"
    original = Kochab.parse(source)
    formatted = Kochab.format(source, indent: 4, keep_blank_lines: 1)
    result = Kochab.parse(formatted)
    assert result.valid?, formatted
    assert_equal original.value, result.value
    assert_equal original.comments.map(&:text), result.comments.map(&:text)
    assert_equal formatted, Kochab.format(formatted, indent: 4, keep_blank_lines: 1)
    refute_includes formatted, "\r\n\r\n\r\n"
    assert_includes formatted, '    "a": ['
    assert_raises(Kochab::ParseError) { Kochab.format('{invalid}') }
    assert_raises(ArgumentError) { Kochab.format('{}', indent: -1) }
  end
end

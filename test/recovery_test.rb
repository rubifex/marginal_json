# frozen_string_literal: true

require_relative "test_helper"
require "timeout"

class RecoveryTest < Minitest::Test
  # Ten independently damaged constructs, each in twenty distinct contexts.
  200.times do |index|
    define_method("test_recovery_#{index}") do
      key = "entry#{index}"
      text = case index % 10
      when 0 then %({"#{key}":})
      when 1 then %({"#{key}" #{index}, "tail": true})
      when 2 then "{\"#{key}\": \"unfinished\n, \"tail\": true}"
      when 3 then %({"#{key}":[#{index},})
      when 4 then %({"#{key}":#{index},])
      when 5 then %({"#{key}":#{index},,"tail":true})
      when 6 then %({"#{key}":#{index} "tail":true})
      when 7 then %({"#{key}":#{index}, "tail": "\\uXXXX"})
      when 8 then %({"#{key}":#{index}, "#{key}":#{index + 1}})
      when 9 then %({"#{key}":#{index}, /* unfinished)
      end
      doc = Timeout.timeout(1) { Kochab.parse(text) }
      assert_kind_of Hash, doc.value
      refute_empty doc.errors
      assert_equal text.bytesize, doc.text.bytesize
      assert doc.errors.all? { |error| error.range.begin >= 0 && error.range.end <= text.bytesize }
    end
  end

  def test_arbitrary_bytes_and_mutated_json_never_crash
    random = Random.new(42)
    seed = '{"editor":{"font":"日本語🙂","size":14},"array":[true,null,1.5]}'
    Timeout.timeout(15) do
      5000.times do |index|
        source = if index.even?
          random.bytes(random.rand(0..180))
        else
          bytes = seed.b.dup
          position = random.rand(0..bytes.bytesize)
          bytes[position, random.rand(0..[8, bytes.bytesize - position].min)] = random.bytes(random.rand(0..8))
          bytes
        end
        doc = Kochab.parse(source)
        assert_kind_of Kochab::Document, doc
        assert_equal source.b, doc.text.b
        assert doc.errors.all? { |error| error.range.begin >= 0 && error.range.end <= source.bytesize }
      end
    end
  end

  def test_consecutive_leading_and_floating_comments
    source = "// floating\n\n// first\n/* second */\n{\n // a\n // b\n \"value\": 1 /* inline */ /* unattached */\n}"
    doc = Kochab.parse(source)
    assert_equal ["// first", "/* second */"], doc.root.leading_comments.map(&:text)
    assert_equal ["// a", "// b"], doc.root.children.first.leading_comments.map(&:text)
    assert_equal ["// floating", "/* unattached */"], doc.floating_comments.map(&:text)
    assigned = doc.floating_comments.dup
    nodes = [doc.root]
    until nodes.empty?
      node = nodes.pop
      assigned.concat(node.leading_comments)
      assigned << node.trailing_comment if node.trailing_comment
      nodes.concat(node.children)
    end
    assert_equal doc.comments.sort_by { |comment| comment.range.begin }, assigned.sort_by { |comment| comment.range.begin }
  end

  def test_generated_valid_json_matches_standard_library
    random = Random.new(91)
    1000.times do
      value = {"文字🙂" => random.rand(-10**10..10**10), "a" => Array.new(random.rand(12)) {
        [nil, true, false, random.rand, "escape\n\t\"\\#{random.rand(100)}"].sample(random: random)
      }}
      text = JSON.generate(value)
      assert_equal JSON.parse(text), Kochab.parse(text, strict: true).value
    end
  end
end

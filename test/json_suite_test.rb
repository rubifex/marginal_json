# frozen_string_literal: true

require_relative "test_helper"

class JSONSuiteTest < Minitest::Test
  Dir[File.join(__dir__, "fixtures/json_test_suite/*.json")].sort.each do |path|
    name = File.basename(path)
    define_method("test_#{name}") do
      source = File.binread(path)
      if name.start_with?("n_")
        assert_raises(Kochab::ParseError, name) { Kochab.parse(source, strict: true) }
      elsif name.start_with?("y_")
        doc = Kochab.parse(source, strict: true)
        assert doc.valid?, name
        expected = JSON.parse(source.force_encoding(Encoding::UTF_8), max_nesting: false, allow_duplicate_key: true)
        expected.nil? ? assert_nil(doc.value) : assert_equal(expected, doc.value)
      else
        begin
          assert Kochab.parse(source, strict: true).valid?
        rescue Kochab::ParseError => error
          refute_empty error.errors
        end
      end
    end
  end
end

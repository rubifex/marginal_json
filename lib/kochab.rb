# frozen_string_literal: true

require "json"
require "strscan"
require_relative "kochab/version"

# JSON with comments, source ranges, and non-destructive editing.
module Kochab
  Error = Struct.new(:range, :code, :message, :severity, keyword_init: true)
  Comment = Struct.new(:range, :text, :kind, keyword_init: true)
  TextEdit = Struct.new(:offset, :length, :text, keyword_init: true)
  Node = Struct.new(:kind, :range, :key_range, :value, :children,
    :leading_comments, :trailing_comment, :key, :parent, keyword_init: true)

  class ParseError < StandardError
    attr_reader :errors

    def initialize(errors)
      @errors = errors
      error = errors.find { |entry| entry.severity == :error }
      super("#{error.message} at byte #{error.range.begin}")
    end
  end

  # Parse UTF-8 bytes. Syntax errors are collected unless strict is true.
  # Duplicate keys are warnings, with the final occurrence winning.
  def self.parse(text, strict: false, trailing_commas: true, allow_nan: false, max_depth: 512)
    raise TypeError, "text must be a String" unless text.is_a?(String)
    unless max_depth.is_a?(Integer) && (1..512).cover?(max_depth)
      raise ArgumentError, "max_depth must be an Integer between 1 and 512"
    end

    Parser.new(text, strict: strict, trailing_commas: trailing_commas,
      allow_nan: allow_nan, max_depth: max_depth).parse
  end

  # Apply non-overlapping byte edits against one source snapshot.
  # Insertions at the same byte offset are concatenated in input order.
  def self.apply(text, edits)
    raise TypeError, "text must be a String" unless text.is_a?(String)

    validate_edits(text, edits)
    ordered = edits.each_with_index.sort_by { |edit, index| [edit.offset, edit.length.zero? ? 0 : 1, index] }
    cursor = 0
    output = String.new(encoding: Encoding::BINARY)
    ordered.each do |edit, _|
      raise ArgumentError, "Text edits overlap" if edit.offset < cursor

      output << text.byteslice(cursor...edit.offset).b << edit.text.b
      cursor = edit.offset + edit.length
    end
    output << text.byteslice(cursor..).b
    output.force_encoding(text.encoding)
  end

  def self.validate_edits(text, edits)
    edits.each do |edit|
      unless edit.is_a?(TextEdit) && edit.offset.is_a?(Integer) && edit.length.is_a?(Integer) &&
          edit.text.is_a?(String) && edit.offset >= 0 && edit.length >= 0 && edit.offset + edit.length <= text.bytesize
        raise ArgumentError, "Invalid text edit"
      end
      if text.encoding == Encoding::UTF_8 && text.valid_encoding?
        [edit.offset, edit.offset + edit.length].each do |offset|
          byte = text.getbyte(offset)
          raise ArgumentError, "Edit splits a UTF-8 character" if byte && byte & 0xc0 == 0x80
        end
        raise ArgumentError, "Replacement is not valid UTF-8" unless edit.text.b.force_encoding(Encoding::UTF_8).valid_encoding?
      end
    end
  end
  private_class_method :validate_edits

  # Normalize whitespace while retaining every comment and token verbatim.
  def self.format(text, indent: 2, keep_blank_lines: 1)
    parse(text).format(indent: indent, keep_blank_lines: keep_blank_lines)
  end
end

require_relative "kochab/parser"
require_relative "kochab/document"
require_relative "kochab/editing"

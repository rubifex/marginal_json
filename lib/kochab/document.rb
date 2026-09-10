# frozen_string_literal: true

module Kochab
  # A parsed source snapshot. Edits refer to this snapshot and do not mutate it.
  class Document
    attr_reader :text, :root, :errors, :comments, :floating_comments

    def initialize(text, root, errors, comments, tokens)
      @text, @root, @errors, @comments, @tokens = text, root, errors, comments, tokens
      @floating_comments = []
    end

    def value
      @root&.value
    end

    def valid?
      @errors.none? { |error| error.severity == :error }
    end

    # Deepest node covering a byte offset. Whitespace belongs to its container.
    def node_at(offset)
      return nil unless offset.is_a?(Integer) && @root && @root.range.cover?(offset)

      current = @root
      loop do
        child = current.children.bsearch { |entry| entry.range.end > offset }
        return current unless child&.range&.cover?(offset)

        current = child
      end
    end

    def path_at(offset)
      current = node_at(offset)
      return nil unless current

      path = []
      while current.parent
        path << current.key if current.kind == :property || current.parent.kind == :array
        current = current.parent
      end
      path.reverse
    end

    def range_of(path)
      entry = find_node(path)
      entry = entry.children.first if entry&.kind == :property
      entry&.range
    end

    def key_range_of(path)
      find_node(path)&.key_range
    end

    # LSP positions count UTF-16 code units, with zero-based lines/columns.
    def utf16_position_at(offset)
      raise EncodingError, "LSP positions require valid UTF-8" unless @text.valid_encoding?
      check_byte_offset(offset)
      line = (line_starts.bsearch_index { |start| start > offset } || line_starts.length) - 1
      prefix = @text.byteslice(line_starts[line]...offset).scrub.sub(/[\r\n]+\z/, "")
      [line, prefix.encode(Encoding::UTF_16LE).bytesize / 2]
    end

    def offset_at_utf16_position(line, character)
      raise EncodingError, "LSP positions require valid UTF-8" unless @text.valid_encoding?
      unless line.is_a?(Integer) && character.is_a?(Integer) && line >= 0 && character >= 0 && line < line_starts.length
        raise RangeError, "UTF-16 position is outside the document"
      end
      start = line_starts[line]
      finish = line_starts[line + 1] || @text.bytesize
      content = @text.byteslice(start...finish).scrub.sub(/[\r\n]+\z/, "")
      units, bytes = 0, 0
      content.each_char do |char|
        break if units == character

        units += char.ord > 0xffff ? 2 : 1
        raise RangeError, "UTF-16 position splits a surrogate pair" if units > character
        bytes += char.bytesize
      end
      raise RangeError, "UTF-16 position is past the line end" unless units == character

      start + bytes
    end

    private

    def check_byte_offset(offset)
      unless offset.is_a?(Integer) && (0..@text.bytesize).cover?(offset)
        raise RangeError, "Byte offset is outside the document"
      end
      byte = @text.getbyte(offset)
      raise RangeError, "Byte offset splits a UTF-8 character" if @text.valid_encoding? && byte && byte & 0xc0 == 0x80
    end

    def line_starts
      @line_starts ||= begin
        result = [0]
        @text.b.to_enum(:scan, /\r\n|\r|\n/n).each { result << Regexp.last_match.end(0) }
        result
      end
    end

    def find_node(path)
      raise TypeError, "path must be an Array" unless path.is_a?(Array)

      path.reduce(@root) do |parent, key|
        parent = parent.children.first if parent&.kind == :property
        case parent&.kind
        when :object
          raise TypeError, "Object path keys must be Strings" unless key.is_a?(String)
          parent.children.reverse_each.find { |child| child.key == key }
        when :array
          raise TypeError, "Array path indices must be nonnegative Integers" unless key.is_a?(Integer) && key >= 0
          parent.children[key]
        else
          nil
        end
      end
    end
  end
end

# frozen_string_literal: true

module Kochab
  class Document
    # Replace the value at path, or insert a missing final object member.
    # Only the value's bytes are replaced; adjacent trivia is never included.
    def set(path, value)
      entry = find_node(path)
      return insert(path, value) unless entry

      entry = entry.children.first if entry.kind == :property
      [TextEdit.new(offset: entry.range.begin, length: entry.range.size, text: JSON.generate(value))]
    end

    # Remove all occurrences of a member, or one array element. Comments outside
    # the removed node survive, as do all whitespace and unrelated tokens.
    def remove(path)
      raise ArgumentError, "Cannot remove the document root; use set([], nil)" if path == []
      entry = find_node(path)
      return [] unless entry
      raise ParseError, errors unless valid?

      entries = entry.kind == :property ? entry.parent.children.select { |child| child.key == entry.key } : [entry]
      edits = entries.flat_map do |child|
        result = [TextEdit.new(offset: child.range.begin, length: child.range.size, text: "")]
        following = token_after(child.range.end)
        preceding = token_before(child.range.begin)
        comma = following&.kind == :comma ? following : (preceding if preceding&.kind == :comma)
        result << TextEdit.new(offset: comma.range.begin, length: 1, text: "") if comma
        result
      end
      edits.uniq { |edit| [edit.offset, edit.length] }
    end

    # Insert a new object key (optionally after another key) or an array index.
    def insert(path, value, after: nil)
      raise TypeError, "path must be a nonempty Array" unless path.is_a?(Array) && !path.empty?
      raise ParseError, errors unless valid?

      parent = find_node(path[0...-1])
      parent = parent.children.first if parent&.kind == :property
      key = path.last
      index = insertion_index(parent, key, after)
      payload = JSON.generate(value)
      payload = "#{JSON.generate(key)}: #{payload}" if parent.kind == :object

      if (following = parent.children[index])
        offset = following.leading_comments.first&.range&.begin || following.range.begin
        prefix = line_prefix(offset)
        separator = prefix.match?(/\A[ \t]*\z/) ? eol + prefix : " "
        return [TextEdit.new(offset: offset, length: 0, text: payload + "," + separator)]
      end
      append_entry(parent, payload)
    end

    # Pretty-print the token stream without decoding/re-encoding strings or comments.
    def format(indent: 2, keep_blank_lines: 1)
      raise ParseError, errors unless valid?
      unless indent.is_a?(Integer) && indent >= 0 && keep_blank_lines.is_a?(Integer) && keep_blank_lines >= 0
        raise ArgumentError, "indent and keep_blank_lines must be nonnegative Integers"
      end
      events = (@tokens.reject { |token| token.kind == :eof } + @comments).sort_by { |event| event.range.begin }
      output = @text.start_with?("\uFEFF") ? +"\uFEFF" : +""
      depth = 0
      previous = nil
      events.each do |event|
        closing = [:object_end, :array_end].include?(event.kind)
        depth -= 1 if closing
        if previous
          gap = @text.byteslice(previous.range.end...event.range.begin)
          newlines = gap.scan(/\r\n|\r|\n/).length
          separator = separator_between(previous, event, newlines)
          if separator == :newline
            output << eol * (1 + [[newlines - 1, 0].max, keep_blank_lines].min)
            output << " " * (indent * depth)
          elsif separator == :space
            output << " "
          end
        end
        output << @text.byteslice(event.range)
        depth += 1 if [:object, :array].include?(event.kind)
        previous = event
      end
      output << eol
    end

    private

    def token_after(offset)
      @tokens.bsearch { |token| token.range.begin >= offset }
    end

    def token_before(offset)
      index = @tokens.bsearch_index { |token| token.range.begin >= offset }
      @tokens[index - 1] if index && index.positive?
    end

    def line_prefix(offset)
      before = @text.byteslice(0...offset)
      before.byteslice((before.b.rindex(/[\r\n]/n) || -1) + 1..)
    end

    def eol
      @eol ||= @text[/\r\n|\r|\n/] || "\n"
    end

    def insertion_index(parent, key, after)
      case parent&.kind
      when :object
        raise TypeError, "Object path keys must be Strings" unless key.is_a?(String)
        raise ArgumentError, "Property already exists; use set" if parent.children.any? { |child| child.key == key }
        return parent.children.length if after.nil?

        found = parent.children.rindex { |child| child.key == after }
        raise KeyError, "No property #{after.inspect} to insert after" unless found

        found + 1
      when :array
        raise ArgumentError, "Use an array index instead of after" unless after.nil?
        unless key.is_a?(Integer) && (0..parent.children.length).cover?(key)
          raise IndexError, "Array insertion index is outside the array"
        end
        key
      else
        raise KeyError, "Parent path is not an object or array"
      end
    end

    def separator_between(previous, event, newlines)
      return :newline if previous.kind == :line
      return newlines.positive? ? :newline : :space if event.is_a?(Comment)
      return :none if [:colon, :comma].include?(event.kind)

      opening = [:object, :array].include?(previous.kind)
      return opening ? :none : :newline if [:object_end, :array_end].include?(event.kind)
      return :newline if opening || previous.kind == :comma
      return :space if previous.kind == :colon
      return newlines.positive? ? :newline : :space if previous.is_a?(Comment)

      :none
    end

    def append_entry(parent, payload)
      closing = token_before(parent.range.end)
      last = parent.children.last
      comma = last && token_after(last.range.end)&.kind == :comma
      edits = []
      edits << TextEdit.new(offset: last.range.end, length: 0, text: ",") if last && !comma
      payload += "," if comma
      if @text.byteslice(parent.range).match?(/[\r\n]/)
        base = line_prefix(parent.range.begin)[/\A[ \t]*/]
        first = parent.children.first
        child_indent = first && line_prefix(first.range.begin)
        child_indent = base + "  " unless child_indent&.match?(/\A[ \t]+\z/) && child_indent.length > base.length
        prefix = line_prefix(closing.range.begin)
        addition = if prefix.match?(/\A[ \t]*\z/) && child_indent.start_with?(prefix)
          child_indent.delete_prefix(prefix)
        else
          eol + child_indent
        end
        payload = addition + payload + eol + base
      elsif last || @comments.any? { |comment| parent.range.cover?(comment.range.begin) }
        payload = " " + payload unless @text.getbyte(closing.range.begin - 1) == 32
      end
      edits << TextEdit.new(offset: closing.range.begin, length: 0, text: payload)
      edits
    end
  end
end

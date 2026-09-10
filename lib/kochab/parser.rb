# frozen_string_literal: true

module Kochab
  # Internal scanner/parser. All offsets are bytes, even for invalid UTF-8.
  class Parser
    Token = Struct.new(:kind, :range, :value)
    PUNCTUATION = {123 => :object, 125 => :object_end, 91 => :array,
      93 => :array_end, 58 => :colon, 44 => :comma}.freeze
    VALUES = [:object, :array, :string, :number, :boolean, :null].freeze
    ENDINGS = [:object_end, :array_end, :eof].freeze
    def initialize(text, strict:, trailing_commas:, allow_nan:, max_depth:)
      @text = text.dup.force_encoding(Encoding::UTF_8).freeze
      @scanner = StringScanner.new(@text.b)
      @strict, @trailing_commas, @allow_nan = strict, trailing_commas, allow_nan
      @max_depth = max_depth
      @errors, @comments, @tokens, @nodes = [], [], [], []
      @index = 0
    end

    def parse
      scan
      root = parse_value(0)
      until current.kind == :eof
        diagnose(current.range, :unexpected_token, "Unexpected token after root value")
        advance
      end
      document = Document.new(@text, root, @errors, @comments, @tokens)
      attach_comments(document)
      raise ParseError, @errors if @strict && !document.valid?

      document
    end

    private

    def diagnose(range, code, message, severity = :error)
      @errors << Error.new(range: range, code: code, message: message, severity: severity)
    end

    def scan
      diagnose(0...@text.bytesize, :invalid_encoding, "Input is not valid UTF-8") unless @text.valid_encoding?
      scan_bom

      until @scanner.eos?
        next if @scanner.skip(/[ \t\r\n]+/n)

        scan_token
      end
      @tokens << Token.new(:eof, @text.bytesize...@text.bytesize)
    end

    def scan_bom
      return unless @scanner.scan(/\xEF\xBB\xBF/n)

      diagnose(0...3, :unexpected_bom, "BOM is not permitted in strict JSON") if @strict
    end

    def scan_token
      start = @scanner.pos
      byte = @scanner.peek(1).getbyte(0)
      if (kind = PUNCTUATION[byte])
        @scanner.pos += 1
        @tokens << Token.new(kind, start...@scanner.pos)
      elsif byte == 34
        scan_string(start)
      elsif @scanner.scan(%r{//[^\r\n]*|/\*(?:[^*]++|\*(?!/))*\*/}n)
        comment(start, @scanner.matched.start_with?("//") ? :line : :block)
      elsif @scanner.scan(%r{/\*}n)
        @scanner.terminate
        comment(start, :block)
        diagnose(start...@scanner.pos, :unterminated_comment, "Unterminated block comment")
      elsif @scanner.scan(/(?:-?Infinity|NaN)/n)
        raw = @scanner.matched
        value = raw == "NaN" ? Float::NAN : (raw.start_with?("-") ? -Float::INFINITY : Float::INFINITY)
        @tokens << Token.new(:number, start...@scanner.pos, value)
        diagnose(start...@scanner.pos, :invalid_number, "Non-finite numbers are disabled") if @strict || !@allow_nan
      elsif @scanner.scan(/-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/n)
        raw = @scanner.matched
        value = raw.match?(/[.eE]/) ? JSON.parse(raw) : raw.to_i
        @tokens << Token.new(:number, start...@scanner.pos, value)
      elsif @scanner.scan(/true|false|null/n)
        raw = @scanner.matched
        @tokens << Token.new(raw == "null" ? :null : :boolean, start...@scanner.pos,
          raw == "null" ? nil : raw == "true")
      else
        @scanner.scan(/[^\s{}\[\]:,"\/]+/n) || @scanner.get_byte
        diagnose(start...@scanner.pos, :invalid_token, "Invalid token")
        @tokens << Token.new(:invalid, start...@scanner.pos)
      end
    end

    def scan_string(start)
      valid = @scanner.scan(/"(?:[^"\\\x00-\x1f]++|\\(?:["\\\/bfnrt]|u[0-9a-fA-F]{4}))*"/n)
      closed = valid || @scanner.scan(/"(?:[^"\\\r\n]++|\\[^\r\n])*"/n)
      @scanner.scan(/"(?:[^"\\\r\n]++|\\[^\r\n])*\\?/n) unless closed
      raw = @scanner.matched.force_encoding(Encoding::UTF_8)
      range = start...@scanner.pos
      unless closed
        diagnose(range, :unterminated_string, "Unterminated string")
        # An unfinished escape has no decoded character yet.
        raw = (raw.b.sub(/\\\z/n, "") + '"').force_encoding(Encoding::UTF_8)
      end
      @tokens << Token.new(:string, range, decode_string(raw, valid, range))
    end

    def decode_string(raw, valid, range)
      begin
        if raw.b.match?(/[\\\x00-\x1f]/n)
          # Older json releases silently accept unknown escapes, so validate
          # their syntax ourselves before asking the decoder for their value.
          raise JSON::ParserError, "Invalid string escape or control character" unless valid
          value = JSON.parse(raw)
        else
          value = raw.byteslice(1, raw.bytesize - 2)
        end
        raise JSON::ParserError, "Invalid Unicode string" unless value.valid_encoding?
      rescue JSON::ParserError, EncodingError
        diagnose(range, :invalid_string, "Invalid string escape, control character, or Unicode")
        value = raw.byteslice(1, [raw.bytesize - 2, 0].max).scrub
      end
      value
    end

    def comment(start, kind)
      range = start...@scanner.pos
      @comments << Comment.new(range: range, text: @text.byteslice(range), kind: kind)
      diagnose(range, :comment_not_allowed, "Comments are not permitted in strict JSON") if @strict
    end

    def current
      @tokens[@index]
    end

    def advance
      token = current
      @index += 1 unless token.kind == :eof
      token
    end

    def node(kind, range, value = nil, children = [], key_range = nil, key = nil)
      result = Node.new(kind: kind, range: range, value: value, children: children,
        key_range: key_range, key: key, leading_comments: [])
      children.each { |child| child.parent = result }
      @nodes << result
      result
    end

    def parse_value(depth)
      token = current
      case token.kind
      when :object, :array
        if depth >= @max_depth
          diagnose(token.range, :depth_limit, "Maximum nesting depth exceeded")
          skip_container
          return node(:null, token.range.begin...@tokens[@index - 1].range.end)
        end
        parse_container(depth + 1)
      when :string, :number, :boolean, :null
        advance
        node(token.kind, token.range, token.value)
      else
        diagnose(token.range, :expected_value, "Expected a value")
        advance unless ENDINGS.include?(token.kind) || token.kind == :comma
        node(:null, token.range.begin...token.range.begin)
      end
    end

    def skip_container
      depth = 0
      loop do
        kind = advance.kind
        depth += 1 if [:object, :array].include?(kind)
        depth -= 1 if [:object_end, :array_end].include?(kind)
        break if depth.zero? || current.kind == :eof
      end
    end

    def parse_container(depth)
      opening = advance
      object = opening.kind == :object
      ending = object ? :object_end : :array_end
      children, value = [], object ? {} : []
      comma = nil
      until current.kind == ending || current.kind == :eof
        if [:object_end, :array_end].include?(current.kind)
          diagnose(current.range, :mismatched_bracket, "Mismatched closing bracket")
          advance
          next
        end
        if current.kind == :comma
          diagnose(current.range, :unexpected_comma, "Unexpected comma")
          comma = advance
          next
        end
        if children.any? && !comma
          diagnose(current.range, :expected_comma, "Expected a comma")
        end
        before = @index
        if object
          child = parse_property(depth)
          if child
            diagnose(child.key_range, :duplicate_key, "Duplicate key #{child.key.inspect}", :warning) if value.key?(child.key)
            value[child.key] = child.value
            children << child
          end
        else
          child = parse_value(depth)
          child.key = children.length
          children << child
          value << child.value
        end
        advance if before == @index
        comma = current.kind == :comma ? advance : nil
      end
      finish = finish_container(ending, comma)
      node(opening.kind, opening.range.begin...finish, value, children)
    end

    def finish_container(ending, comma)
      if current.kind == ending
        diagnose(comma.range, :trailing_comma, "Trailing comma is not permitted") if comma && (@strict || !@trailing_commas)
        advance.range.end
      else
        diagnose(current.range, :unclosed_container, "Expected #{ending == :object_end ? '}' : ']'}")
        @text.bytesize
      end
    end

    def parse_property(depth)
      unless current.kind == :string
        diagnose(current.range, :expected_key, "Expected a quoted property name")
        advance
        return nil
      end
      key = advance
      if current.kind == :colon
        advance
      else
        diagnose(current.range, :expected_colon, "Expected ':' after property name")
      end
      value = parse_value(depth)
      node(:property, key.range.begin...value.range.end, value.value, [value], key.range, key.value)
    end

    def attach_comments(document)
      return if @comments.empty?

      ends = @nodes
      starts = comment_targets(document.root)
      next_comment = nil
      leading_target = nil
      @comments.reverse_each do |comment|
        previous = comment_target_before(ends, comment)
        following = starts.bsearch { |entry| entry.range.begin >= comment.range.end }
        gap_before = previous && @text.byteslice(previous.range.end...comment.range.begin).b
        if next_comment && leading_target && (!following || next_comment.range.begin < following.range.begin)
          following = leading_target
          end_of_gap = next_comment.range.begin
        else
          end_of_gap = following&.range&.begin
        end
        gap_after = end_of_gap && @text.byteslice(comment.range.end...end_of_gap).b
        leading_target = nil
        if previous && !previous.trailing_comment && gap_before.match?(/\A[ \t,]*\z/n)
          previous.trailing_comment = comment
        elsif following && gap_after.match?(/\A\s*\z/) && gap_after.scan(/\r\n|\r|\n/).length <= 1
          following.leading_comments.unshift(comment)
          leading_target = following
        else
          document.floating_comments << comment
        end
        next_comment = comment
      end
      document.floating_comments.sort_by! { |comment| comment.range.begin }
    end

    def comment_targets(root)
      starts = []
      pending = [root]
      until pending.empty?
        entry = pending.pop
        starts << entry unless entry.parent&.kind == :property
        entry.children.reverse_each { |child| pending << child }
      end
      starts
    end

    def comment_target_before(ends, comment)
      # Nodes are constructed in postorder, so end offsets are already sorted.
      before = ends.bsearch_index { |entry| entry.range.end > comment.range.begin } || ends.length
      previous = before.positive? ? ends[before - 1] : nil
      # Equal end offsets belong to the innermost value, before its property.
      while before > 1 && ends[before - 2].range.end == previous.range.end
        before -= 1
        previous = ends[before - 1]
      end
      previous
    end
  end
end

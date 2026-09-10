# frozen_string_literal: true

require "kochab"

source = <<~JSONC
  {
    // Size in points; this comment survives the update.
    "editor": { "font_size": 12, "theme": "dark" },
  }
JSONC

document = Kochab.parse(source)
updated = Kochab.apply(source, document.set(["editor", "font_size"], 14))
puts updated
raise "Unexpected edit" unless updated == source.sub("12", "14")

document = Kochab.parse(updated)
puts "Font size bytes: #{document.range_of(['editor', 'font_size'])}"
puts "LSP position: #{document.utf16_position_at(document.range_of(['editor', 'font_size']).begin)}"

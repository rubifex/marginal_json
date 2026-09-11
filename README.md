<h1 align="center">Kochab</h1>

<p align="center">
  <strong>JSONC parsing with byte ranges, error recovery, and formatting-preserving edits</strong>
</p>

<p align="center">
  <a href="https://rubygems.org/gems/kochab"><img src="https://img.shields.io/gem/v/kochab.svg?colorB=319e8c" alt="Gem Version"></a>
  <a href="https://rubygems.org/gems/kochab"><img src="https://img.shields.io/gem/dt/kochab.svg" alt="Downloads"></a>
  <a href="https://github.com/noxdea/kochab/actions/workflows/main.yml"><img src="https://github.com/noxdea/kochab/actions/workflows/main.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/ruby-%3E%3D%203.1-CC342D.svg" alt="Ruby 3.1+">
  <a href="LICENSE.txt"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"></a>
</p>

<p align="center">
  <a href="#features">Features</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#quick-start">Quick Start</a> ·
  <a href="#source-queries">Source Queries</a> ·
  <a href="#editing">Editing</a> ·
  <a href="#development">Development</a>
</p>

---

Kochab is a pure Ruby JSONC parser that retains exact source locations. It
recovers from syntax errors and produces minimal text edits that preserve
surrounding comments and formatting.

## Features

- JSONC parsing with comments and trailing commas
- UTF-8 byte ranges, syntax tree queries, and UTF-16 position conversion
- Error recovery with structured diagnostics and a strict JSON mode
- Minimal insert, replace, and remove edits that preserve unrelated source text
- Comment-preserving formatting
- RBS signatures with no runtime gem dependencies

## Installation

Add Kochab to your Gemfile:

```ruby
gem "kochab"
```

Then install:

```sh
bundle install
```

Or install it directly:

```sh
gem install kochab
```

Kochab requires Ruby 3.1 or later.

## Quick Start

```ruby
require "kochab"

text = <<~JSONC
  {
    // Font size in points
    "editor": { "font_size": 12, "theme": "dark" },
  }
JSONC

doc = Kochab.parse(text)
doc.value                              # {"editor" => {"font_size" => 12, ...}}
doc.valid?                             # true
doc.errors                             # []

edits = doc.set(["editor", "font_size"], 14)
updated = Kochab.apply(text, edits)
raise unless updated == text.sub("12", "14")
```

Every offset and range is measured in **UTF-8 bytes**, and ranges exclude the
end offset. Ruby `String#[]` indexes characters: use `String#byteslice(range)`
to extract source ranges. Input strings are treated as UTF-8 bytes; other
encodings are not transcoded because that would change their offsets.

## Source queries

```ruby
range = doc.range_of(["editor", "font_size"])
text.byteslice(range)                       # "12"
doc.key_range_of(["editor", "font_size"])   # includes the key's quotes
doc.node_at(range.begin).kind               # :number
doc.path_at(range.begin)                    # ["editor", "font_size"]
position = doc.utf16_position_at(range.begin) # [line, UTF-16 column], zero-based
doc.offset_at_utf16_position(*position)      # inverse conversion
```

Array paths use nonnegative integer indices. Missing paths return `nil`.
`node_at` descends by binary search through sorted children. Whitespace inside
a container resolves to that container; offsets outside the root return `nil`.
UTF-16 conversions reject out-of-range positions, split UTF-8 characters,
split surrogate pairs, and invalid UTF-8. LF, CRLF, and CR are recognized.
Positions inside a CRLF delimiter map to the preceding line's end.

Nodes expose `kind`, `range`, `key_range`, `value`, `children`,
`leading_comments`, `trailing_comment`, `parent`, and `key`. Kinds are
`:object`, `:array`, `:property`, `:string`, `:number`, `:boolean`, and `:null`.
Property nodes have one value child; a missing value is a zero-length `:null`
node. Containers' `value` fields contain their Ruby Hash or Array values.
Treat the tree and its values as read-only snapshots. `doc.text` is frozen.

## Parsing and Recovery

The default parser consumes the complete input and reports syntax problems in
`doc.errors`, including invalid UTF-8. It returns the best available value:

```ruby
doc = Kochab.parse('{"a" 1, "b": , "c": 3}')
doc.value                 # {"a" => 1, "b" => nil, "c" => 3}
doc.errors.map(&:code)    # [:expected_colon, :expected_value]
doc.valid?                # false

Kochab.parse('{"a":1}', strict: true) # standard JSON only
```

`strict: true` raises `Kochab::ParseError` for invalid syntax and exposes
all diagnostics through the exception's `errors`. Comments, a BOM, trailing
commas, and named non-finite numbers are rejected in strict mode. Duplicate
keys produce `:duplicate_key` warnings and the last occurrence wins; warnings
do not make `valid?` false. Diagnostic fields are `range`, `code`, `message`,
and `severity` (`:error` or `:warning`).

| Option | Default | Meaning |
| --- | --- | --- |
| `trailing_commas` | `true` | Set to `false` to diagnose trailing commas |
| `allow_nan` | `false` | Opt into `NaN`, `Infinity`, `-Infinity` literals |
| `max_depth` | `512` | Maximum nesting depth; configurable from 1 to 512 |

Unfinished strings end at a line break or EOF; missing colons and commas are
diagnosed and recovered; unmatched closing brackets are skipped. Overdeep
subtrees are skipped iteratively and replaced by `nil`. This bounds the Ruby
call stack while still consuming the document. Integers retain arbitrary
precision; floats follow Ruby JSON's overflow/underflow behavior. JSON5 features
(unquoted keys, single quotes, hexadecimal numbers) are excluded. Wrong
argument types still raise normal Ruby exceptions.

All comments are available as `doc.comments`; each has `range`, `text`, and
`:line` or `:block` `kind`. Contiguous comments immediately above a node attach
as `leading_comments`. A same-line comment after a value attaches to that
value's `trailing_comment`. Comments separated by a blank line, and additional
comments that cannot occupy the single trailing slot, are `floating_comments`.
Comment text always retains its original delimiters and bytes.

## Editing

```ruby
doc.set(["editor", "font_size"], 14)                 # replace one value
doc.insert(["editor", "language"], "ja", after: "theme")
doc.remove(["editor", "theme"])                      # delete member + comma
doc.insert(["recent_files", 0], "/tmp/notes.txt")     # insert into an array
doc.set([], {"new_root" => true})                     # replace the root
```

Each method returns `TextEdit` objects with `offset`, `length`, and `text`.
`set` changes only the value's byte span and can repair an unfinished value;
it inserts a missing final member when its parent exists. `insert` rejects an
existing object key; omitted `after` appends. `remove` removes every duplicate
occurrence of the requested object key; an absent key is a no-op.

Insertion preserves all existing bytes. Removal deletes the requested node
and its required comma, leaving unrelated whitespace and comments intact.
Comments inside a removed/replaced subtree belong to that subtree and are
removed with it. Removing a node can leave blank lines or detached comments.
`insert` and `remove` require a valid document; `set` can repair a recovered
node using its recorded value span.

Edits use the original snapshot's coordinates. Reparse after applying edits
before generating further edits. `apply` validates bounds, UTF-8 boundaries,
replacement encoding, and overlap. Same-offset insertions are concatenated in
input order; insertions at a replacement's start precede that replacement.
It builds the output in one pass without mutating the original string.

## Formatting

```ruby
pretty = Kochab.format(text, indent: 2, keep_blank_lines: 1)
```

Formatting normalizes indentation and spacing, preserves every comment and
literal token verbatim (including escaped strings and trailing commas), uses
the first newline style present in the input, and appends one final newline.
`keep_blank_lines` limits consecutive blank lines between tokens. Formatting
rejects invalid documents to avoid discarding incomplete input. Use minimal
edits when existing whitespace must be preserved exactly.

## Development

```sh
bundle install
bundle exec rake test          # complete suite, including fuzz and JSON oracle
bundle exec rake test:oracle   # all 318 pinned upstream JSONTestSuite cases
bundle exec rake test:fuzz     # 200 recovery cases + 5,000 random/mutated inputs
bundle exec rake isolation
bundle exec rake bench:assert  # Ruby with YJIT; machine-dependent budgets
ruby -Ilib examples/settings.rb
```

Tests include all `y_`, `n_`, and `i_` parsing cases from
[JSONTestSuite](https://github.com/nst/JSONTestSuite), pinned in
`test/fixtures/json_test_suite/PROVENANCE.md` with its MIT license. Every `y_`
case must pass and every `n_` case must fail; upstream explicitly permits either
outcome for `i_` cases. Valid inputs are also checked against `JSON.parse`.
Recovery/fuzz tests check termination, source preservation, and bounded ranges.
Edit tests check exact replacement bytes and preservation of unrelated comments.

## Performance

Measured on macOS arm64, Ruby 4.0.0 with YJIT (2026-09-09), seven-sample medians:

| Operation | Observed | Budget |
| --- | ---: | ---: |
| Parse 10,256-byte JSONC | 1.13 ms | 2 ms |
| Parse 1,048,594-byte JSONC | 157.5 ms | 200 ms |
| Query `node_at` | < 1 µs | 10 µs |
| Generate a `set` edit | 2 µs | 1 ms |

The corpus contains nested settings, UTF-8 strings, and one comment per setting.
Run `bench/benchmark.rb` on your deployment machine; these are measurements,
not timing guarantees. CI uses three times these limits on shared runners.
Parsing uses memory proportional to input size. Queries
cost O(depth × log siblings). Object path lookup scans members, whereas
byte-position queries use binary search.

CI tests Ruby 3.1, 3.2, 3.3, 3.4, and 4.0 on Linux, macOS, and Windows. Performance
budgets run separately on Linux with Ruby 4.0 and YJIT. Built-gem installation
and the example are smoke-tested in CI.

## Contributing

Bug reports and pull requests are welcome on
[GitHub](https://github.com/noxdea/kochab).

See [CHANGELOG.md](CHANGELOG.md) for release history.

## License

MIT; see [LICENSE.txt](LICENSE.txt). Vendored test data retains its original
MIT notice. The implementation does not depend on `jsonc-parser`; its
[source API](https://github.com/microsoft/node-jsonc-parser) is a reference for
the editor-facing behavior.

# frozen_string_literal: true

require_relative "../lib/kochab"

def configuration(bytes)
  source = +"{\n"
  index = 0
  while source.bytesize < bytes - 2
    source << "  // Setting #{index}\n  \"setting_#{index}\": {\"size\": #{index}, \"font\": \"日本語🙂\"},\n"
    index += 1
  end
  source << "}\n"
end

def median(iterations, &block)
  samples = Array.new(7) do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    iterations.times(&block)
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / iterations
  end
  samples.sort[samples.length / 2]
end

small = configuration(10 * 1024)
large = configuration(1024 * 1024)
50.times { Kochab.parse(small) }
document = Kochab.parse(small)
path = ["setting_100", "font"]
offset = document.range_of(path).begin
budget_scale = ENV["CI"] ? 3 : 1
results = {
  "parse_10kb" => [median(20) { Kochab.parse(small) }, 0.002 * budget_scale],
  "parse_1mb" => [median(2) { Kochab.parse(large) }, 0.200 * budget_scale],
  "node_at" => [median(10_000) { document.node_at(offset) }, 0.000010 * budget_scale],
  "set" => [median(2_000) { document.set(path, "Fira Code") }, 0.001 * budget_scale]
}
puts RUBY_DESCRIPTION
puts "YJIT: #{defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?}; sources: #{small.bytesize}, #{large.bytesize} bytes"
results.each { |name, (seconds, limit)| puts "%12s %9.3f ms (budget %.3f ms)" % [name, seconds * 1000, limit * 1000] }
abort "Performance budget exceeded" if ARGV.include?("--assert") && results.any? { |_, (seconds, limit)| seconds > limit }

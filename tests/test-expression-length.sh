#!/usr/bin/env bash
# Regressionstest gegen GitHubs Ausdrucksgrenze: eine run:- oder script:-Zeichenkette mit `${{`
# wird von GitHub zu EINEM Ausdruck kompiliert und bei mehr als 21000 Zeichen samt der ganzen
# Datei abgelehnt ("Exceeded max expression length 21000", Lauf ohne Jobs, "workflow file issue").
# actionlint meldet das nicht. Gemessen wird die Länge nach dem Ausrücken (YAML-geparst).
# Rot ab 21000, Warnung ab 18000 (die kompilierte Form ist länger als der Rohtext).
# Blöcke ohne `${{` unterliegen der Grenze nicht (Werte per env: und envs: übergeben).
#
# Aufruf: tests/test-expression-length.sh [Datei-oder-Verzeichnis ...]   (Standard: .github/workflows)
# Rotprobe: tests/test-expression-length.sh <Fassung von v1.8.1> muss rot werden (Exit 1).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$#" -eq 0 ]; then set -- "$HERE/../.github/workflows"; fi

ruby -ryaml - "$@" <<'RUBY'
FAIL_AT = 21_000
WARN_AT = 18_000
files = ARGV.flat_map { |a| File.directory?(a) ? Dir[File.join(a, '*.{yml,yaml}')].sort : [a] }
abort 'keine Workflow-Dateien gefunden' if files.empty?

def walk(node, path, &blk)
  case node
  when Hash
    node.each do |k, v|
      if %w[run script].include?(k.to_s) && v.is_a?(String)
        blk.call("#{path}/#{k}", v)
      else
        walk(v, "#{path}/#{k}", &blk)
      end
    end
  when Array
    node.each_with_index { |v, i| walk(v, "#{path}[#{i}]", &blk) }
  end
end

pass = fail = warn = 0
files.each do |f|
  data = YAML.load_file(f)
  walk(data, File.basename(f)) do |where, str|
    n = str.scan('${{').size
    next if n.zero?
    if str.size >= FAIL_AT
      fail += 1
      puts "  FEHLT #{where}: #{str.size} Zeichen mit #{n} Ausdrücken (Grenze #{FAIL_AT})"
    elsif str.size >= WARN_AT
      pass += 1
      warn += 1
      puts "  WARNT #{where}: #{str.size} Zeichen mit #{n} Ausdrücken (Warnschwelle #{WARN_AT}, Grenze #{FAIL_AT})"
    else
      pass += 1
      puts "  ok    #{where}: #{str.size} Zeichen, #{n} Ausdrücke"
    end
  end
end
puts "== Ergebnis: #{pass} ok (davon #{warn} Warnung), #{fail} fehlend"
exit(fail.zero? ? 0 : 1)
RUBY

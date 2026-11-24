#!/usr/bin/env ruby
# frozen_string_literal: true

# Gibt den run-Block (oder bei ssh-Schritten den script-Eingang) eines Schritts aus
# deploy-hetzner.yml aus. Aufruf: extract-step.rb <workflow.yml> <job> <schritt-id-oder-name-teil> [--key run|script]
# Ersetzt ${{ inputs.<name> }} und ${{ github.sha }} durch Werte aus der Umgebung
# (INPUT_<NAME> mit Bindestrich als Unterstrich, GITHUB_SHA_VALUE), damit der Block
# lokal ausführbar ist. Alle anderen Ausdrücke bleiben unverändert.
require 'yaml'

wf, job, wanted, *rest = ARGV
key = rest.include?('--key') ? rest[rest.index('--key') + 1] : 'run'
data = YAML.load_file(wf)
steps = data.fetch('jobs').fetch(job).fetch('steps')
step = steps.find { |s| s['id'] == wanted } || steps.find { |s| s['name'].to_s.include?(wanted) }
abort "Schritt nicht gefunden: #{job}/#{wanted}" unless step

def resolve(text)
  text = text.gsub(/\$\{\{\s*inputs\.([a-z-]+)\s*\}\}/) { ENV.fetch("INPUT_#{Regexp.last_match(1).tr('-', '_').upcase}", '') }
  text = text.gsub(/\$\{\{\s*github\.sha\s*\}\}/) { ENV.fetch('GITHUB_SHA_VALUE', '') }
  text = text.gsub(/\$\{\{\s*env\.STAGING_DIR\s*\}\}/) { ENV.fetch('STAGING_DIR_VALUE', '/tmp/quick-deploy-RUN-1') }
  # server-config-files: Hashliste aus detect-changes (NEEDS_CONFIG_HASHES) und Staging am Ziel (CFG_STAGE_VALUE)
  text = text.gsub(/\$\{\{\s*needs\.detect-changes\.outputs\.config-hashes\s*\}\}/) { ENV.fetch('NEEDS_CONFIG_HASHES', '') }
  text.gsub(/\$\{\{\s*env\.CFG_STAGE\s*\}\}/) { ENV.fetch('CFG_STAGE_VALUE', '/tmp/cfg-stage-RUN-1') }
end

text = key == 'script' ? step.fetch('with').fetch('script') : step.fetch('run')
text = resolve(text)

# ssh-Schritte mit envs: stellt die Umgebungsvariablen voran, wie appleboy/ssh-action (drone-ssh) sie
# überträgt: `export NAME='Wert'` mit Einfachklammern, ' als '\''. Der Wert ist der aufgelöste Ausdruck
# aus env: des Schritts; Werte, die nach dem Auflösen noch ${{ enthalten (Secrets, needs.*.base),
# werden nicht ausgegeben (der Test setzt sie selbst).
prefix = +''
if key == 'script'
  names = step.fetch('with', {})['envs'].to_s.split(',').map(&:strip).reject(&:empty?)
  names.each do |name|
    raw = (step['env'] || {})[name]
    next if raw.nil?
    val = resolve(raw.to_s)
    next if val.include?('${{')
    prefix << "export #{name}='#{val.gsub("'") { "'\\''" }}'\n"
  end
end
print prefix + text

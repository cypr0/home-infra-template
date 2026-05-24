set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-euo', 'pipefail']

[group: 'bootstrap']
mod? bootstrap 'bootstrap'

[group: 'kubernetes']
mod? kube 'kubernetes'

[group: 'capmox']
mod? capmox 'capmox'

[private]
default:
    just -l

[private]
log lvl msg *args:
    gum log -t rfc3339 -s -l "{{ lvl }}" "{{ msg }}" {{ args }}

# === template ===

[group: 'template']
mod template 'template'

[doc('Render and validate configuration files')]
[group('template')]
configure:
    just template configure

[doc('Initialize configuration files (cluster.toml, age key, deploy key, push token)')]
[group('template')]
init:
    just template init

[doc('Full end-to-end cluster deployment')]
[group('cluster')]
up:
    just template configure
    just bootstrap mgmt
    just capmox deploy
    just bootstrap apps

# === Firewall ===

[doc('Configure OPNsense firewall (permissive mode for initial setup)')]
[group('firewall')]
firewall-setup:
    ./scripts/configure-opnsense-firewall.sh --mode=permissive

[doc('Configure OPNsense firewall (production mode with explicit rules)')]
[group('firewall')]
firewall-production:
    ./scripts/configure-opnsense-firewall.sh --mode=production

[doc('Test firewall configuration (dry-run)')]
[group('firewall')]
firewall-test mode='production':
    ./scripts/configure-opnsense-firewall.sh --dry-run --mode={{ mode }}

# === Preflight ===

[doc('Run preflight checks before deployment')]
[group('setup')]
preflight:
    ./scripts/preflight.sh

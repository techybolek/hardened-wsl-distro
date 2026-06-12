#!/usr/bin/env bash
# Outbound firewall: default DROP, allow only explicitly listed destinations.
# Ported from Anthropic's claude-code devcontainer init-firewall.sh.

set -euo pipefail
IFS=$'\n\t'

log() { echo "[init-firewall] $*"; }

# --- Reset iptables and ipset ---
# IMPORTANT: reset policies to ACCEPT FIRST so the bootstrap fetches below can reach the network.
# Flushing rules alone leaves the default policy from the previous run (which may already be DROP).
iptables -P INPUT ACCEPT
iptables -P OUTPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# --- Baseline ACCEPT rules (evaluated before default DROP policy kicks in) ---
# Allow established/related connections
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow DNS (UDP+TCP 53) — required to resolve the allow-list itself
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# Allow DHCP (so WSL networking can renew leases)
iptables -A OUTPUT -p udp --dport 67:68 -j ACCEPT

# Allow outbound to the Windows host's local SQL Server (cloned dev DBs on .\SQLEXPRESS),
# so the TPV2 backend can run against the local clone. Under WSL2 NAT the Windows host is
# the default gateway, whose IP changes on every WSL restart — resolve it at runtime rather
# than listing a (stale) static IP. Scoped to the SQLEXPRESS TCP port only, to keep the
# distro's outbound isolation otherwise intact. WIN_SQL_PORT mirrors the port in
# backend/tp/configurations/local/config_local_localdb.js (SQLEXPRESS dynamic port; update
# both if it changes after a SQL service restart).
WIN_SQL_PORT=64341
win_host=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')
if [ -n "${win_host:-}" ]; then
  iptables -A OUTPUT -p tcp -d "$win_host" --dport "$WIN_SQL_PORT" -j ACCEPT
  log "Allowed outbound to Windows host $win_host:$WIN_SQL_PORT (local SQLEXPRESS)"
else
  log "WARNING: could not resolve Windows host (default gateway); local SQL not allowed"
fi

# Allow SSH inbound (so wsl.exe -d works fine; harmless either way)
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
# Allow SSH inbound on 2222 for VS Code Remote-SSH (sshd bound to 127.0.0.1:2222)
iptables -A INPUT -p tcp --dport 2222 -j ACCEPT

# --- Build allow-list ipset ---
ipset create allowed-domains hash:net family inet hashsize 4096 maxelem 65536

# GitHub: pull CIDRs from their meta endpoint
log "Fetching GitHub IP ranges..."
gh_meta=$(curl -fsSL --max-time 15 https://api.github.com/meta || echo '{}')
echo "$gh_meta" | jq -r '
  (.web // []) + (.api // []) + (.git // []) + (.packages // []) + (.actions // [])
  | .[]' | while read -r cidr; do
    [ -n "$cidr" ] && ipset add allowed-domains "$cidr" 2>/dev/null || true
done

# AWS CloudFront: pull current edge CIDRs from AWS's published IP-ranges document.
# Docker Hub image blobs are served via CloudFront (production.cloudfront.docker.com),
# and CloudFront rotates across a large global edge pool that DNS-at-startup cannot pin.
log "Fetching AWS CloudFront IP ranges..."
aws_ranges=$(curl -fsSL --max-time 15 https://ip-ranges.amazonaws.com/ip-ranges.json || echo '{}')
echo "$aws_ranges" | jq -r '.prefixes[] | select(.service=="CLOUDFRONT") | .ip_prefix' \
  | while read -r cidr; do
    [ -n "$cidr" ] && ipset add allowed-domains "$cidr" 2>/dev/null || true
done

# AWS Global Accelerator: ECR Public (public.ecr.aws) is fronted by Global Accelerator
# anycast IPs (e.g. 99.83.x, 75.2.x). Without these, `docker pull` from public.ecr.aws
# times out at TCP. Reuses $aws_ranges already fetched above.
log "Fetching AWS Global Accelerator IP ranges..."
echo "$aws_ranges" | jq -r '.prefixes[] | select(.service=="GLOBALACCELERATOR") | .ip_prefix' \
  | while read -r cidr; do
    [ -n "$cidr" ] && ipset add allowed-domains "$cidr" 2>/dev/null || true
done

# Google published IP ranges: storage.googleapis.com (and other Google services) sit
# behind a large rotating edge pool spread across many /16s. The published list at
# gstatic.com is reachable during the bootstrap ACCEPT window at the top of this script.
log "Fetching Google IP ranges..."
goog_ranges=$(curl -fsSL --max-time 15 https://www.gstatic.com/ipranges/goog.json || echo '{}')
echo "$goog_ranges" | jq -r '.prefixes[] | .ipv4Prefix // empty' \
  | while read -r cidr; do
    [ -n "$cidr" ] && ipset add allowed-domains "$cidr" 2>/dev/null || true
done

# Domain and direct-IP allow-lists live in sibling files alongside this script.
# Format: one entry per line; blank lines and `#` comments are ignored. Inline
# `# ...` comments after an entry are stripped.
script_dir=$(dirname "$(readlink -f "$0")")
domains_file="$script_dir/allowed-domains.list"
ips_file="$script_dir/allowed-ips.list"

read_list() {
  # Strip inline comments, then trim surrounding whitespace, then drop blanks
  # and full-line comments. Emits one cleaned entry per line.
  local f=$1
  [ -f "$f" ] || { log "WARNING: list file not found: $f"; return; }
  sed -E 's/[[:space:]]*#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' "$f" \
    | grep -vE '^$'
}

log "Loading direct IPs/CIDRs from $ips_file..."
while IFS= read -r ip; do
  [ -n "$ip" ] && ipset add allowed-domains "$ip" 2>/dev/null || true
done < <(read_list "$ips_file")

log "Resolving allow-listed domains from $domains_file..."
while IFS= read -r domain; do
  [ -n "$domain" ] || continue
  ips=$(dig +short +time=3 +tries=2 A "$domain" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
  for ip in $ips; do
    ipset add allowed-domains "$ip" 2>/dev/null || true
  done
done < <(read_list "$domains_file")

count=$(ipset list allowed-domains | grep -c '^[0-9]')
log "Allow-list contains $count entries"

# --- Allow outbound to allow-list ---
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# --- Default DROP policies ---
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

log "Firewall active (default OUTPUT=DROP, allow-list applied)"

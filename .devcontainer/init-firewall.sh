#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# ファイアウォールの ON/OFF 制御
# ENABLE_FIREWALL=false で無効化（プロキシ環境での切り分け等に利用）
if [ "${ENABLE_FIREWALL:-true}" = "false" ]; then
    echo "Firewall disabled (ENABLE_FIREWALL=false). Skipping firewall configuration."
    exit 0
fi

# 1. Reset default policies to ACCEPT before flushing
# (previous run may have set them to DROP)
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
ip6tables -P INPUT ACCEPT
ip6tables -P FORWARD ACCEPT
ip6tables -P OUTPUT ACCEPT

# Flush existing filter rules and ipsets
# NOTE: NAT table is NOT flushed — Docker depends on it for DNS resolution
# (127.0.0.11) and container networking. Flushing NAT would break Docker.
iptables -F
iptables -X
iptables -t mangle -F
iptables -t mangle -X
ip6tables -F
ip6tables -X
ipset destroy allowed-domains 2>/dev/null || true
ipset destroy allowed-domains-v6 2>/dev/null || true

# Allow DNS, SSH, and localhost (IPv4)
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# IPv6: Allow localhost and DNS, drop everything else by default
ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A OUTPUT -o lo -j ACCEPT
ip6tables -A OUTPUT -p udp --dport 53 -j ACCEPT
ip6tables -A INPUT -p udp --sport 53 -j ACCEPT
ip6tables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
ip6tables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Create ipsets with CIDR support (IPv4 + IPv6)
ipset create allowed-domains hash:net
ipset create allowed-domains-v6 hash:net family inet6

# Fetch GitHub IP ranges
echo "Fetching GitHub IP ranges..."
gh_ranges=$(curl -s https://api.github.com/meta)
if [ -z "$gh_ranges" ]; then
    echo "ERROR: Failed to fetch GitHub IP ranges"
    exit 1
fi

if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
    echo "ERROR: GitHub API response missing required fields"
    exit 1
fi

echo "Processing GitHub IPs..."
while read -r cidr; do
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "ERROR: Invalid CIDR range from GitHub meta: $cidr"
        exit 1
    fi
    echo "Adding GitHub range $cidr"
    ipset add allowed-domains "$cidr" -exist
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)

# Add well-known CIDR ranges for CDN services (IPs rotate frequently)
# Google: https://support.google.com/a/answer/10026322
echo "Adding Google CIDR ranges..."
for cidr in \
    "142.250.0.0/15" \
    "172.217.0.0/16" \
    "216.58.192.0/19" \
    "172.253.0.0/16" \
    "74.125.0.0/16"; do
    ipset add allowed-domains "$cidr" -exist
done
for cidr6 in \
    "2404:6800::/32" \
    "2607:f8b0::/32" \
    "2a00:1450::/32" \
    "2800:3f0::/32"; do
    ipset add allowed-domains-v6 "$cidr6" -exist
done

# Resolve and add other allowed domains (A + AAAA records)
for domain in \
    "registry.npmjs.org" \
    "cdn.npmjs.org" \
    "registry.yarnpkg.com" \
    "raw.githubusercontent.com" \
    "codeload.githubusercontent.com" \
    "objects.githubusercontent.com" \
    "user-images.githubusercontent.com" \
    "api.anthropic.com" \
    "claude.ai" \
    "context7.com" \
    "mcp.context7.com" \
    "api.context7.com" \
    "repo1.maven.org" \
    "plugins.gradle.org" \
    "services.gradle.org" \
    "pypi.org" \
    "files.pythonhosted.org" \
    "marketplace.visualstudio.com" \
    "vscode.blob.core.windows.net" \
    "update.code.visualstudio.com" \
    "api.openai.com" \
    "openaipublic.blob.core.windows.net" \
    "cloud.langfuse.com" \
    "us.cloud.langfuse.com"; do
    echo "Resolving $domain..."

    # IPv4 (A records)
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [ -n "$ips" ]; then
        while read -r ip; do
            if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                echo "  Adding IPv4 $ip for $domain"
                ipset add allowed-domains "$ip" -exist
            fi
        done < <(echo "$ips")
    fi

    # IPv6 (AAAA records)
    ip6s=$(dig +noall +answer AAAA "$domain" | awk '$4 == "AAAA" {print $5}')
    if [ -n "$ip6s" ]; then
        while read -r ip6; do
            echo "  Adding IPv6 $ip6 for $domain"
            ipset add allowed-domains-v6 "$ip6" -exist
        done < <(echo "$ip6s")
    fi

    if [ -z "$ips" ] && [ -z "$ip6s" ]; then
        echo "  WARNING: Failed to resolve $domain (skipping)"
    fi
done

# Get host IP from default route and allow Docker network communication
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
fi

HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
echo "Host network detected as: $HOST_NETWORK"

iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# Allow all Docker bridge networks (172.16.0.0/12) for inter-container communication
# This covers docker-compose networks like langfuse_default
echo "Allowing Docker bridge networks (172.16.0.0/12)..."
iptables -A INPUT -s 172.16.0.0/12 -j ACCEPT
iptables -A OUTPUT -d 172.16.0.0/12 -j ACCEPT

# Allow host.docker.internal (Docker Desktop host access)
# FIREWALL_ALLOWED_PORTS: ホスト側サービス (Streamlit, LangFuse 等) へのアクセスを
# 許可するポート。.env で設定する（例: 443,80,3000,8501）
HOST_DOCKER_IP=$(dig +short A host.docker.internal 2>/dev/null || true)
HOST_DOCKER_IP6=$(dig +short AAAA host.docker.internal 2>/dev/null || true)
if [ -n "$HOST_DOCKER_IP" ] || [ -n "$HOST_DOCKER_IP6" ]; then
    ALLOWED_PORTS="${FIREWALL_ALLOWED_PORTS:-443,80}"
    echo "Allowing host.docker.internal (IPv4: ${HOST_DOCKER_IP:-none}, IPv6: ${HOST_DOCKER_IP6:-none}) on ports: $ALLOWED_PORTS..."
    IFS=',' read -ra PORTS <<< "$ALLOWED_PORTS"
    for port in "${PORTS[@]}"; do
        if [ -n "$HOST_DOCKER_IP" ]; then
            iptables -A OUTPUT -d "$HOST_DOCKER_IP" -p tcp --dport "$port" -j ACCEPT
            iptables -A INPUT -s "$HOST_DOCKER_IP" -p tcp --sport "$port" -m state --state ESTABLISHED -j ACCEPT
        fi
        if [ -n "$HOST_DOCKER_IP6" ]; then
            ip6tables -A OUTPUT -d "$HOST_DOCKER_IP6" -p tcp --dport "$port" -j ACCEPT
            ip6tables -A INPUT -s "$HOST_DOCKER_IP6" -p tcp --sport "$port" -m state --state ESTABLISHED -j ACCEPT
        fi
    done
fi

# Set default policies to DROP (IPv4 and IPv6)
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT DROP

# Allow established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow outbound traffic to allowed domains only (IPv4 + IPv6)
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
ip6tables -A OUTPUT -m set --match-set allowed-domains-v6 dst -j ACCEPT

# Reject all other outbound traffic
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
ip6tables -A OUTPUT -j REJECT --reject-with icmp6-adm-prohibited

echo "Firewall configuration complete"
echo "Verifying firewall rules..."
if curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://example.com"
    exit 1
else
    echo "Firewall verification passed - unable to reach https://example.com as expected"
fi

if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://api.github.com"
    exit 1
else
    echo "Firewall verification passed - able to reach https://api.github.com as expected"
fi

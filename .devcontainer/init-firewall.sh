#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# ファイアウォールの ON/OFF 制御
# ENABLE_FIREWALL=false で無効化（プロキシ環境での切り分け等に利用）
if [ "${ENABLE_FIREWALL:-true}" = "false" ]; then
    echo "Firewall disabled (ENABLE_FIREWALL=false). Skipping firewall configuration."
    exit 0
fi

# --- DNS 解決ヘルパー（リトライ付き） ---
# resolve_domain <domain> → stdout に IP を出力、失敗時は空
DNS_RETRY_COUNT=3
DNS_RETRY_DELAY=2

resolve_a() {
    local domain="$1"
    local attempt
    for attempt in $(seq 1 "$DNS_RETRY_COUNT"); do
        local result
        result=$(dig +noall +answer +tries=1 +time=5 A "$domain" 2>/dev/null | awk '$4 == "A" {print $5}')
        if [ -n "$result" ]; then
            echo "$result"
            return 0
        fi
        if [ "$attempt" -lt "$DNS_RETRY_COUNT" ]; then
            echo "  Retry ($attempt/$DNS_RETRY_COUNT) A record for $domain..." >&2
            sleep "$DNS_RETRY_DELAY"
        fi
    done
    return 1
}

resolve_aaaa() {
    local domain="$1"
    local attempt
    for attempt in $(seq 1 "$DNS_RETRY_COUNT"); do
        local result
        result=$(dig +noall +answer +tries=1 +time=5 AAAA "$domain" 2>/dev/null | awk '$4 == "AAAA" {print $5}')
        if [ -n "$result" ]; then
            echo "$result"
            return 0
        fi
        if [ "$attempt" -lt "$DNS_RETRY_COUNT" ]; then
            echo "  Retry ($attempt/$DNS_RETRY_COUNT) AAAA record for $domain..." >&2
            sleep "$DNS_RETRY_DELAY"
        fi
    done
    return 1
}

# --- 重要ドメイン定義 ---
# これらのドメインが解決できない場合、ファイアウォール初期化を中止する
CRITICAL_DOMAINS=(
    "api.anthropic.com"
    "claude.ai"
    "api.github.com"
    "registry.npmjs.org"
)

# --- サマリー用カウンター ---
SUMMARY_IPV4_COUNT=0
SUMMARY_IPV6_COUNT=0
SUMMARY_FAILED_DOMAINS=()

# --- IPv6 利用可否チェック ---
HAS_IPV6=true
if ! ip -6 route show default >/dev/null 2>&1; then
    echo "NOTE: IPv6 not available. Skipping all IPv6 (AAAA) resolution and rules."
    HAS_IPV6=false
fi

# 1. Reset default policies to ACCEPT before flushing
# (previous run may have set them to DROP)
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
if [ "$HAS_IPV6" = true ]; then
    ip6tables -P INPUT ACCEPT
    ip6tables -P FORWARD ACCEPT
    ip6tables -P OUTPUT ACCEPT
fi

# Flush existing filter rules and ipsets
# NOTE: NAT table is NOT flushed — Docker depends on it for DNS resolution
# (127.0.0.11) and container networking. Flushing NAT would break Docker.
iptables -F
iptables -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true
if [ "$HAS_IPV6" = true ]; then
    ip6tables -F
    ip6tables -X
    ipset destroy allowed-domains-v6 2>/dev/null || true
fi

# Allow DNS, SSH, and localhost (IPv4)
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# IPv6: Allow localhost and DNS, drop everything else by default
if [ "$HAS_IPV6" = true ]; then
    ip6tables -A INPUT -i lo -j ACCEPT
    ip6tables -A OUTPUT -o lo -j ACCEPT
    ip6tables -A OUTPUT -p udp --dport 53 -j ACCEPT
    ip6tables -A INPUT -p udp --sport 53 -j ACCEPT
    ip6tables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
fi

# Create ipsets with CIDR support (IPv4 + IPv6)
ipset create allowed-domains hash:net
if [ "$HAS_IPV6" = true ]; then
    ipset create allowed-domains-v6 hash:net family inet6
fi

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

# Fetch AWS IP ranges (selected regions + GLOBAL, service=AMAZON super-set)
# Covers S3 / EC2 / STS / KMS / IAM / Route53 etc. without manual host enumeration.
# IPs rotate frequently — AWS CLI may switch endpoints between requests.
# AWS_REGION_ALLOW: space-separated. us-east-1 is required for ACM certs used by
# Cognito custom domain (ACM cert for Cognito must live in us-east-1).
AWS_REGION_ALLOW="${AWS_REGION_ALLOW:-ap-northeast-1 us-east-1}"
# IFS=$'\n\t' のため $AWS_REGION_ALLOW のスペース区切りが split されない。
# 明示的に配列へ展開する。
IFS=' ' read -ra AWS_REGION_ALLOW_ARR <<< "$AWS_REGION_ALLOW"
echo "Fetching AWS IP ranges for ${AWS_REGION_ALLOW_ARR[*]} + GLOBAL..."
aws_ranges=$(curl -fsSL https://ip-ranges.amazonaws.com/ip-ranges.json) || \
    { echo "ERROR: Failed to fetch AWS ip-ranges.json"; exit 1; }

if ! echo "$aws_ranges" | jq -e '.prefixes and .ipv6_prefixes' >/dev/null; then
    echo "ERROR: AWS ip-ranges.json missing required fields"
    exit 1
fi

# IPv4 prefixes for selected regions (AMAZON super-set)
for aws_region in "${AWS_REGION_ALLOW_ARR[@]}"; do
    while read -r cidr; do
        [ -z "$cidr" ] && continue
        echo "Adding AWS IPv4 range $cidr ($aws_region)"
        ipset add allowed-domains "$cidr" -exist
    done < <(echo "$aws_ranges" | jq -r --arg region "$aws_region" \
        '.prefixes[] | select(.region == $region) | select(.service == "AMAZON") | .ip_prefix' \
        | (aggregate -q 2>/dev/null || cat))
done

# IPv4 GLOBAL prefixes (region-less endpoints: IAM, Route53, etc.)
# Route53 / Route53 health-check IPs are published under their own service
# categories (not always under AMAZON super-set), so include them explicitly.
while read -r cidr; do
    [ -z "$cidr" ] && continue
    echo "Adding AWS GLOBAL IPv4 range $cidr"
    ipset add allowed-domains "$cidr" -exist
done < <(echo "$aws_ranges" | jq -r \
    '.prefixes[] | select(.region == "GLOBAL") | select(.service == "AMAZON" or .service == "ROUTE53" or .service == "ROUTE53_HEALTHCHECKS") | .ip_prefix' \
    | (aggregate -q 2>/dev/null || cat))

# IPv6 prefixes for selected region (only when IPv6 stack is available)
if [ "$HAS_IPV6" = true ]; then
    for aws_region in "${AWS_REGION_ALLOW_ARR[@]}"; do
        while read -r cidr6; do
            [ -z "$cidr6" ] && continue
            echo "Adding AWS IPv6 range $cidr6 ($aws_region)"
            ipset add allowed-domains-v6 "$cidr6" -exist
        done < <(echo "$aws_ranges" | jq -r --arg region "$aws_region" \
            '.ipv6_prefixes[] | select(.region == $region) | select(.service == "AMAZON") | .ipv6_prefix')
    done

    # IPv6 GLOBAL prefixes (parity with IPv4 GLOBAL block above).
    # Includes Route53 GLOBAL IPv6 endpoints.
    while read -r cidr6; do
        [ -z "$cidr6" ] && continue
        echo "Adding AWS GLOBAL IPv6 range $cidr6"
        ipset add allowed-domains-v6 "$cidr6" -exist
    done < <(echo "$aws_ranges" | jq -r \
        '.ipv6_prefixes[] | select(.region == "GLOBAL") | select(.service == "AMAZON" or .service == "ROUTE53") | .ipv6_prefix')
fi

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
if [ "$HAS_IPV6" = true ]; then
    for cidr6 in \
        "2404:6800::/32" \
        "2607:f8b0::/32" \
        "2a00:1450::/32" \
        "2800:3f0::/32"; do
        ipset add allowed-domains-v6 "$cidr6" -exist
    done
fi

# Resolve and add other allowed domains (A + AAAA records)
ALL_DOMAINS=(
    "registry.npmjs.org"
    "cdn.npmjs.org"
    "registry.yarnpkg.com"
    "raw.githubusercontent.com"
    "codeload.githubusercontent.com"
    "objects.githubusercontent.com"
    "user-images.githubusercontent.com"
    "api.anthropic.com"
    "claude.ai"
    "api.github.com"
    "context7.com"
    "mcp.context7.com"
    "api.context7.com"
    "repo1.maven.org"
    "plugins.gradle.org"
    "services.gradle.org"
    "pypi.org"
    "files.pythonhosted.org"
    "marketplace.visualstudio.com"
    "vscode.blob.core.windows.net"
    "update.code.visualstudio.com"
    "api.openai.com"
    "openaipublic.blob.core.windows.net"
    "cloud.langfuse.com"
    "us.cloud.langfuse.com"
    # Playwright Chromium ダウンロード用 CDN
    # （プロジェクトごとに異なる playwright バージョンで Chromium を追加取得できるように）
    "cdn.playwright.dev"
    "playwright.azureedge.net"
    "finance.yahoo.com"
    "query1.finance.yahoo.com"                                                                                                                   
    "query2.finance.yahoo.com"
                                   
    # === AWS IP Ranges API ===
    # ip-ranges.json を fetch する curl 自身を許可するため
    "ip-ranges.amazonaws.com"

    # === AWS SSO (mra-dev) ===
    # CloudFront 等別プールで CIDR fetch ではカバーできないため明示
    "oidc.ap-northeast-1.amazonaws.com"                 
    "portal.sso.ap-northeast-1.amazonaws.com"           
    "device.sso.ap-northeast-1.amazonaws.com"           
    "signin.aws.amazon.com"
    # SSO start URL のサブドメイン (実際の URL に置換)  
    # "d-xxxxxxxxxx.awsapps.com"                        

    # === AWS Auth ===                                  
    "sts.amazonaws.com"
    "sts.ap-northeast-1.amazonaws.com"          
    "iam.amazonaws.com"
    
    # === Terraform state ===
    "s3.ap-northeast-1.amazonaws.com"                   
    "mra-dev-terraform-state.s3.ap-northeast-1.amazonaws.com"                                                   
    "dynamodb.ap-northeast-1.amazonaws.com"
    
    # === KMS / Secrets ===
    "kms.ap-northeast-1.amazonaws.com"
    "secretsmanager.ap-northeast-1.amazonaws.com"
 
    # === Service APIs ===                              
    "ec2.ap-northeast-1.amazonaws.com"                  
    "ecs.ap-northeast-1.amazonaws.com"
    "ecr.ap-northeast-1.amazonaws.com"                  
    "api.ecr.ap-northeast-1.amazonaws.com"
    "rds.ap-northeast-1.amazonaws.com"
    "elasticache.ap-northeast-1.amazonaws.com"
    "elasticfilesystem.ap-northeast-1.amazonaws.com"
    "cognito-idp.ap-northeast-1.amazonaws.com"
    "route53.amazonaws.com"
    "acm.ap-northeast-1.amazonaws.com"
    # Cognito 用 ACM 証明書は us-east-1 必須
    "acm.us-east-1.amazonaws.com"
    "elasticloadbalancing.ap-northeast-1.amazonaws.com" 
    "wafv2.ap-northeast-1.amazonaws.com"
    "lambda.ap-northeast-1.amazonaws.com"
    "logs.ap-northeast-1.amazonaws.com"
    "monitoring.ap-northeast-1.amazonaws.com"
    "events.ap-northeast-1.amazonaws.com"
    "application-autoscaling.ap-northeast-1.amazonaws.com"
    "servicediscovery.ap-northeast-1.amazonaws.com"
    "ssm.ap-northeast-1.amazonaws.com"
    "ssmmessages.ap-northeast-1.amazonaws.com"
)

is_critical_domain() {
    local domain="$1"
    for critical in "${CRITICAL_DOMAINS[@]}"; do
        if [ "$domain" = "$critical" ]; then
            return 0
        fi
    done
    return 1
}

for domain in "${ALL_DOMAINS[@]}"; do
    echo "Resolving $domain..."
    domain_resolved=false

    # IPv4 (A records) — リトライ付き
    ips=$(resolve_a "$domain" || true)
    if [ -n "$ips" ]; then
        while read -r ip; do
            if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                echo "  Adding IPv4 $ip for $domain"
                ipset add allowed-domains "$ip" -exist
                SUMMARY_IPV4_COUNT=$((SUMMARY_IPV4_COUNT + 1))
                domain_resolved=true
            fi
        done < <(echo "$ips")
    fi

    # IPv6 (AAAA records) — IPv6 が利用可能な場合のみ
    if [ "$HAS_IPV6" = true ]; then
        ip6s=$(resolve_aaaa "$domain" || true)
        if [ -n "$ip6s" ]; then
            while read -r ip6; do
                echo "  Adding IPv6 $ip6 for $domain"
                ipset add allowed-domains-v6 "$ip6" -exist
                SUMMARY_IPV6_COUNT=$((SUMMARY_IPV6_COUNT + 1))
                domain_resolved=true
            done < <(echo "$ip6s")
        fi
    fi

    if [ "$domain_resolved" = false ]; then
        if is_critical_domain "$domain"; then
            echo "  ERROR: Failed to resolve critical domain: $domain"
            echo "  This domain is required for Claude Code to function."
            echo "  Check DNS connectivity and retry."
            exit 1
        else
            echo "  WARNING: Failed to resolve $domain (skipping)"
            SUMMARY_FAILED_DOMAINS+=("$domain")
        fi
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
HOST_DOCKER_IP6=""
if [ "$HAS_IPV6" = true ]; then
    HOST_DOCKER_IP6=$(dig +short AAAA host.docker.internal 2>/dev/null || true)
fi
if [ -n "$HOST_DOCKER_IP" ] || [ -n "$HOST_DOCKER_IP6" ]; then
    ALLOWED_PORTS="${FIREWALL_ALLOWED_PORTS:-443,80}"
    echo "Allowing host.docker.internal (IPv4: ${HOST_DOCKER_IP:-none}, IPv6: ${HOST_DOCKER_IP6:-none}) on ports: $ALLOWED_PORTS..."
    IFS=',' read -ra PORTS <<< "$ALLOWED_PORTS"
    for port in "${PORTS[@]}"; do
        if [ -n "$HOST_DOCKER_IP" ]; then
            iptables -A OUTPUT -d "$HOST_DOCKER_IP" -p tcp --dport "$port" -j ACCEPT
            iptables -A INPUT -s "$HOST_DOCKER_IP" -p tcp --sport "$port" -m state --state ESTABLISHED -j ACCEPT
        fi
        if [ "$HAS_IPV6" = true ] && [ -n "$HOST_DOCKER_IP6" ]; then
            ip6tables -A OUTPUT -d "$HOST_DOCKER_IP6" -p tcp --dport "$port" -j ACCEPT
            ip6tables -A INPUT -s "$HOST_DOCKER_IP6" -p tcp --sport "$port" -m state --state ESTABLISHED -j ACCEPT
        fi
    done
fi

# Set default policies to DROP (IPv4 and IPv6)
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP
if [ "$HAS_IPV6" = true ]; then
    ip6tables -P INPUT DROP
    ip6tables -P FORWARD DROP
    ip6tables -P OUTPUT DROP
fi

# Allow established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow outbound traffic to allowed domains only (IPv4 + IPv6)
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
if [ "$HAS_IPV6" = true ]; then
    ip6tables -A OUTPUT -m set --match-set allowed-domains-v6 dst -j ACCEPT
fi

# Reject all other outbound traffic
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
if [ "$HAS_IPV6" = true ]; then
    ip6tables -A OUTPUT -j REJECT --reject-with icmp6-adm-prohibited
fi

# --- ファイアウォール初期化サマリー ---
echo ""
echo "=========================================="
echo " Firewall initialization summary"
echo "=========================================="
echo "  IPv4 addresses added : $SUMMARY_IPV4_COUNT"
echo "  IPv6 addresses added : $SUMMARY_IPV6_COUNT"
echo "  IPv6 available       : $HAS_IPV6"
if [ ${#SUMMARY_FAILED_DOMAINS[@]} -gt 0 ]; then
    echo "  Unresolved (non-critical):"
    for d in "${SUMMARY_FAILED_DOMAINS[@]}"; do
        echo "    - $d"
    done
else
    echo "  Unresolved domains   : none"
fi
echo "=========================================="
echo ""

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

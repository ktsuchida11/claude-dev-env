#!/usr/bin/env python3
"""MCP server version auto-bump.

7 日クールダウンを満たす最新版を npm / GitHub から取得し、
.devcontainer/mcp-servers.json と .devcontainer/Dockerfile、
README.md の pin テーブルを更新する。

Usage:
  python3 .github/scripts/mcp-version-bump.py            # apply
  python3 .github/scripts/mcp-version-bump.py --dry-run  # show what would change
  python3 .github/scripts/mcp-version-bump.py --print    # just print resolved versions
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

COOLDOWN_DAYS = 7
PRERELEASE_PATTERN = re.compile(r"alpha|beta|rc|canary|next|preview", re.IGNORECASE)
USER_AGENT = "cldev-book-mcp-bump"

REPO_ROOT = Path(__file__).resolve().parents[2]
MCP_SERVERS_JSON = REPO_ROOT / ".devcontainer" / "mcp-servers.json"
DOCKERFILE = REPO_ROOT / ".devcontainer" / "Dockerfile"
README = REPO_ROOT / "README.md"


def http_get_json(url: str) -> dict:
    req = urllib.request.Request(
        url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())


def cooldown_boundary() -> str:
    """ISO 8601 boundary string. Versions with publish date ≤ this are eligible."""
    boundary = datetime.now(timezone.utc) - timedelta(days=COOLDOWN_DAYS)
    return boundary.strftime("%Y-%m-%dT%H:%M:%SZ")


def latest_npm_stable(pkg: str, boundary: str) -> str:
    data = http_get_json(f"https://registry.npmjs.org/{pkg}")
    times = data.get("time", {})
    candidates: list[tuple[str, str]] = []
    for version, ts in times.items():
        if version in ("created", "modified"):
            continue
        if PRERELEASE_PATTERN.search(version):
            continue
        if ts <= boundary:
            candidates.append((ts, version))
    if not candidates:
        sys.exit(f"ERROR: no stable {pkg} version satisfies cooldown {boundary}")
    candidates.sort()
    return candidates[-1][1]


def latest_serena_pin(boundary: str) -> tuple[str, str]:
    """Returns (tag, commit_sha). Picks newest tag whose commit is older than boundary."""
    tags = http_get_json("https://api.github.com/repos/oraios/serena/tags?per_page=20")
    for tag in tags:
        sha = tag["commit"]["sha"]
        commit = http_get_json(f"https://api.github.com/repos/oraios/serena/commits/{sha}")
        date = commit["commit"]["committer"]["date"]
        if date <= boundary:
            return tag["name"], sha
    sys.exit("ERROR: no serena tag satisfies cooldown")


def update_mcp_servers_json(c7: str, pw: str, serena_sha: str) -> bool:
    """Patch via regex to preserve human-curated array formatting."""
    raw = MCP_SERVERS_JSON.read_text()
    new = re.sub(
        r'"@upstash/context7-mcp@[^"]*"',
        f'"@upstash/context7-mcp@{c7}"',
        raw,
    )
    new = re.sub(
        r'"@playwright/mcp@[^"]*"',
        f'"@playwright/mcp@{pw}"',
        new,
    )
    new = re.sub(
        r'"git\+https://github\.com/oraios/serena@[^"]*"',
        f'"git+https://github.com/oraios/serena@{serena_sha}"',
        new,
    )
    # Validate that JSON still parses
    json.loads(new)
    if new == raw:
        return False
    MCP_SERVERS_JSON.write_text(new)
    return True


def update_dockerfile(c7: str, pw: str) -> bool:
    raw = DOCKERFILE.read_text()
    new = re.sub(
        r"^ARG CONTEXT7_MCP_VERSION=.*$",
        f"ARG CONTEXT7_MCP_VERSION={c7}",
        raw,
        flags=re.MULTILINE,
    )
    new = re.sub(
        r"^ARG PLAYWRIGHT_MCP_VERSION=.*$",
        f"ARG PLAYWRIGHT_MCP_VERSION={pw}",
        new,
        flags=re.MULTILINE,
    )
    if new == raw:
        return False
    DOCKERFILE.write_text(new)
    return True


def update_readme(c7: str, pw: str, serena_tag: str, serena_sha: str) -> bool:
    raw = README.read_text()
    new = raw

    # Pin table rows
    new = re.sub(
        r"\| context7 \| npm `@upstash/context7-mcp` \| `[^`]*` \|",
        f"| context7 | npm `@upstash/context7-mcp` | `{c7}` |",
        new,
    )
    new = re.sub(
        r"\| playwright \| npm `@playwright/mcp` \| `[^`]*` \|",
        f"| playwright | npm `@playwright/mcp` | `{pw}` |",
        new,
    )
    new = re.sub(
        r"\| serena \| git `oraios/serena` \| commit `[0-9a-f]+`（[^）]*）\|",
        f"| serena | git `oraios/serena` | commit `{serena_sha}`（{serena_tag} 相当）|",
        new,
    )

    # Verification example commands
    new = re.sub(
        r"uvx --from git\+https://github\.com/oraios/serena@[0-9a-f]+ serena --help",
        f"uvx --from git+https://github.com/oraios/serena@{serena_sha} serena --help",
        new,
    )
    new = re.sub(
        r"npx @playwright/mcp@\S+ --help",
        f"npx @playwright/mcp@{pw} --help",
        new,
    )

    if new == raw:
        return False
    README.write_text(new)
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--print", action="store_true", help="Only print resolved versions")
    args = parser.parse_args()

    boundary = cooldown_boundary()
    print(f"Cooldown boundary: {boundary}", file=sys.stderr)

    c7 = latest_npm_stable("@upstash/context7-mcp", boundary)
    pw = latest_npm_stable("@playwright/mcp", boundary)
    serena_tag, serena_sha = latest_serena_pin(boundary)

    print(f"context7-mcp:       {c7}")
    print(f"playwright/mcp:     {pw}")
    print(f"serena:             {serena_sha} ({serena_tag})")

    if args.print:
        return 0

    changed = False
    if args.dry_run:
        # Compute changes without writing
        original = {p: p.read_text() for p in (MCP_SERVERS_JSON, DOCKERFILE, README)}
        update_mcp_servers_json(c7, pw, serena_sha)
        update_dockerfile(c7, pw)
        update_readme(c7, pw, serena_tag, serena_sha)
        for p, before in original.items():
            after = p.read_text()
            if before != after:
                changed = True
                print(f"would update: {p.relative_to(REPO_ROOT)}", file=sys.stderr)
            p.write_text(before)
    else:
        changed |= update_mcp_servers_json(c7, pw, serena_sha)
        changed |= update_dockerfile(c7, pw)
        changed |= update_readme(c7, pw, serena_tag, serena_sha)

    if not changed:
        print("No changes — current pins already at latest cooldown-eligible versions.", file=sys.stderr)
        return 0

    # GitHub Actions output
    gh_out = sys.stdout if "GITHUB_OUTPUT" not in __import__("os").environ else open(
        __import__("os").environ["GITHUB_OUTPUT"], "a"
    )
    print(f"context7={c7}", file=gh_out)
    print(f"playwright={pw}", file=gh_out)
    print(f"serena_tag={serena_tag}", file=gh_out)
    print(f"serena_sha={serena_sha}", file=gh_out)
    print("changed=true", file=gh_out)
    return 0


if __name__ == "__main__":
    sys.exit(main())

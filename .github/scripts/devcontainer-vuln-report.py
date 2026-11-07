#!/usr/bin/env python3
"""DevContainer vulnerability report.

Trivy の JSON 出力（image の vuln スキャン / config の misconfig スキャン）を集計し、
Issue / PR / ジョブサマリー用の Markdown と、ワークフロー判定用の件数を出力する。

- 修正版のある CRITICAL / HIGH を一覧化し、devcontainer-version-bump.py のどの依存を
  更新すれば解消するか（対処方法）を Target / PkgPath から推定して添える
- 修正版の無いものは件数と折りたたみ一覧のみ（対処しようがないため Issue のノイズにしない）
- 設定ミス（CRITICAL / HIGH）は件数を出力し、スキャン対象ファイルとあわせて毎回レポートに明記する

Usage:
  python3 .github/scripts/devcontainer-vuln-report.py --image image.json [--config config.json] \
      [--ignorefile .devcontainer/.trivyignore.yaml] [--summary report.md]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path

SEVERITIES = ["CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN"]
ACTIONABLE = {"CRITICAL", "HIGH"}
MAX_ROWS = 100  # Issue 本文の上限 (65536 文字) 対策

# 対処方法の種別
BUMP = "依存更新"  # devcontainer-version-bump.py の依存の新版で解消（pin が上流の最新なら上流のリリース待ち）
REBUILD = "再ビルド"  # ビルド時に最新を取得しているため、修正版の公開後に再ビルドすれば解消
MANUAL = "手動調査"

# /usr/local/bin 等に置いている単体バイナリ → bump スクリプトの依存名
BINARIES = {
    "terraform": "terraform",
    "tflint": "tflint",
    "terraform-docs": "terraform-docs",
    "trivy": "trivy",
    "gitleaks": "gitleaks",
    "sops": "sops",
    "gh": "gh",
    "rtk": "rtk",
    "delta": "git-delta",
    "session-manager-plugin": "session-manager-plugin",
    "uv": "uv",
    "uvx": "uv",
}

# グローバル npm パッケージ → bump スクリプトの依存名
NPM_PACKAGES = {
    "@upstash/context7-mcp": "context7-mcp",
    "@playwright/mcp": "playwright-mcp",
    "typescript-language-server": "typescript-language-server",
    "typescript": "typescript",
    "pyright": "pyright",
}


@dataclass(frozen=True)
class Finding:
    vuln_id: str
    severity: str
    pkg: str
    installed: str
    fixed: str
    location: str
    remedy_kind: str
    remedy: str
    url: str


def remedy_for(result: dict, vuln: dict) -> tuple[str, str]:
    """(種別, 対処内容) を返す。対処内容が bump の依存名の場合は `--only` に渡せる名前。"""
    cls, typ, target = result.get("Class", ""), result.get("Type", ""), result.get("Target", "")
    path = vuln.get("PkgPath") or target

    if cls == "os-pkgs":
        return REBUILD, "Debian パッケージ（ベースイメージ digest の追従 + 再ビルド）"

    if typ in ("gobinary", "rustbinary"):
        if "/.local/share/claude/" in f"/{path}" or Path(path).name == "claude":
            return REBUILD, "Claude Code（CLAUDE_CODE_VERSION）"
        if "docker" in Path(path).name or "/cli-plugins/" in path:
            return REBUILD, "docker-ce-cli / plugins（APT）"
        if "sessionmanagerplugin" in path:
            return BUMP, "session-manager-plugin"
        name = BINARIES.get(Path(path).name)
        return (BUMP, name) if name else (MANUAL, f"`{path}`")

    if typ == "node-pkg":
        m = re.search(r"node_modules/((?:@[^/]+/)?[^/]+)/", path)
        top = m.group(1) if m else ""
        if "npm-global/" not in path and top in ("npm", "corepack"):
            return BUMP, "node"  # Node 同梱の npm / corepack
        if top in NPM_PACKAGES:
            return BUMP, NPM_PACKAGES[top]
        return MANUAL, f"npm `{top or path}`"

    if typ in ("python-pkg", "pip"):
        if "aws-cli" in path:
            return REBUILD, "AWS CLI（ビルド時に最新を取得）"
        if vuln.get("PkgName") in ("pip", "uv"):
            return BUMP, vuln["PkgName"]
        # pip/_vendor/bom.cdx.json（pip 同梱の SBOM）由来の検出には PkgPath が付かない。
        # 同梱の msgpack / urllib3 などは再ビルドでは更新されず、新しい pip が必要
        if not vuln.get("PkgPath"):
            return BUMP, "pip"
        return REBUILD, "Python パッケージ（langfuse / pip-audit / playwright。ビルド時に最新を取得）"

    if typ == "jar":
        for key, name in (("apache-maven", "maven"), ("gradle", "gradle"), ("jdtls", "jdtls")):
            if key in path:
                return BUMP, name
        return MANUAL, f"`{path}`"

    return MANUAL, f"`{target}`"


def load_findings(image_json: dict, remedy: str | None = None) -> list[Finding]:
    seen: set[tuple] = set()
    findings = []
    for result in image_json.get("Results") or []:
        for v in result.get("Vulnerabilities") or []:
            location = v.get("PkgPath") or result.get("Target", "")
            key = (v["VulnerabilityID"], v.get("PkgName"), v.get("InstalledVersion"), location)
            if key in seen:
                continue
            seen.add(key)
            kind, how = (BUMP, remedy) if remedy else remedy_for(result, v)
            findings.append(
                Finding(
                    vuln_id=v["VulnerabilityID"],
                    severity=v.get("Severity", "UNKNOWN"),
                    pkg=v.get("PkgName", ""),
                    installed=v.get("InstalledVersion", ""),
                    fixed=v.get("FixedVersion", ""),
                    location=location,
                    remedy_kind=kind,
                    remedy=how,
                    url=v.get("PrimaryURL", ""),
                )
            )
    order = {s: i for i, s in enumerate(SEVERITIES)}
    return sorted(findings, key=lambda f: (order.get(f.severity, 99), f.remedy, f.pkg, f.vuln_id))


def load_misconfigs(config_json: dict) -> list[dict]:
    out = []
    for result in config_json.get("Results") or []:
        for m in result.get("Misconfigurations") or []:
            if m.get("Status") == "FAIL" and m.get("Severity") in ACTIONABLE:
                out.append({**m, "Target": result.get("Target", "")})
    return out


def count_ignores(path: str | None) -> int:
    if not path or not Path(path).exists():
        return 0
    return len(re.findall(r"^\s*-\s+id:", Path(path).read_text(), re.M))


def cell(s: str) -> str:
    return s.replace("|", "\\|").replace("\n", " ")


def vuln_link(f: Finding) -> str:
    return f"[{f.vuln_id}]({f.url})" if f.url else f.vuln_id


def vuln_rows(findings: list[Finding]) -> list[str]:
    rows = ["| ID | 重大度 | パッケージ | 現在 → 修正版 | 場所 | 対処 |", "|---|---|---|---|---|---|"]
    for f in findings[:MAX_ROWS]:
        rows.append(
            f"| {vuln_link(f)} | {f.severity} | {cell(f.pkg)} | `{cell(f.installed)}` → `{cell(f.fixed) or '-'}` "
            f"| `{cell(f.location)}` | {f.remedy_kind}: {cell(f.remedy)} |"
        )
    if len(findings) > MAX_ROWS:
        rows.append(f"\n…ほか {len(findings) - MAX_ROWS} 件（全件はワークフローの artifact を参照）")
    return rows


def fingerprint(findings: list[Finding]) -> str:
    """修正版のある CRITICAL / HIGH の集合の指紋。前回と同じなら自動更新の再起動を省くために使う。"""
    keys = sorted(
        f"{f.vuln_id}|{f.pkg}|{f.installed}|{f.location}" for f in findings if f.fixed and f.severity in ACTIONABLE
    )
    return hashlib.sha256("\n".join(keys).encode()).hexdigest()[:16] if keys else ""


def render(
    image_json: dict,
    findings: list[Finding],
    misconfigs: list[dict],
    ignores: int,
    title: str,
    config_targets: list[str] | None = None,
) -> str:
    fixable = [f for f in findings if f.fixed]
    unfixed = [f for f in findings if not f.fixed]
    lines = [f"## {title}", ""]
    if fp := fingerprint(findings):
        lines += [f"<!-- vuln-fingerprint: {fp} -->", ""]
    meta = [f"対象: `{image_json.get('ArtifactName', '?')}`"]
    if image_json.get("CreatedAt"):
        meta.append(f"スキャン日時: {image_json['CreatedAt'][:19].replace('T', ' ')} UTC")
    lines += [" / ".join(meta), ""]

    lines += ["| 重大度 | 修正版あり | 修正版なし |", "|---|---|---|"]
    for s in SEVERITIES:
        a = sum(1 for f in fixable if f.severity == s)
        b = sum(1 for f in unfixed if f.severity == s)
        if a or b:
            lines.append(f"| {s} | {a} | {b} |")
    if not findings:
        lines.append("| - | 0 | 0 |")

    actionable = [f for f in fixable if f.severity in ACTIONABLE]
    lines += ["", f"### 修正版のある CRITICAL / HIGH（{len(actionable)} 件）", ""]
    if actionable:
        groups: dict[tuple[str, str], int] = {}
        for f in actionable:
            groups[(f.remedy_kind, f.remedy)] = groups.get((f.remedy_kind, f.remedy), 0) + 1
        lines.append("対処方法別:")
        lines.append("")
        for (kind, remedy), n in sorted(groups.items()):
            lines.append(f"- **{kind}** {remedy}: {n} 件")
        if any(kind == BUMP for kind, _ in groups):
            lines += [
                "",
                "「依存更新」は新版が出ていれば `devcontainer-version-update` の PR で取り込まれる"
                "（`devcontainer-version-bump.py --only <名前>` で個別更新も可）。"
                "pin が既に上流の最新の場合（Go / Rust バイナリが古いツールチェーンでビルドされている等）は"
                "上流のリリース待ちとなるため、影響を評価して `.trivyignore.yaml` での期限付き受容を検討すること。"
                "公開 7 日未満の修正版しか無い場合は、クールダウン例外を手動で判断すること。",
            ]
        lines += [""] + vuln_rows(actionable)
    else:
        lines.append("ありません。")

    lines += ["", f"### 設定ミス（trivy config, CRITICAL / HIGH: {len(misconfigs)} 件）", ""]
    if config_targets:
        lines += ["スキャン対象: " + " / ".join(f"`{t}`" for t in config_targets), ""]
    if not misconfigs:
        lines.append("ありません。")
    else:
        lines += [
            "依存の更新では解消しないため、該当ファイルを修正するか、影響を評価して"
            " `.trivyignore.yaml` に理由と期限を付けて受容すること。",
            "",
            "| ID | 重大度 | ファイル | 内容 |",
            "|---|---|---|---|",
        ]
        for m in misconfigs[:MAX_ROWS]:
            lines.append(
                f"| {m.get('ID', '')} | {m.get('Severity', '')} | `{cell(m['Target'])}` "
                f"| {cell(m.get('Title', ''))}: {cell(m.get('Message', ''))} |"
            )

    unfixed_actionable = [f for f in unfixed if f.severity in ACTIONABLE]
    if unfixed_actionable:
        lines += [
            "",
            f"<details><summary>修正版の無い CRITICAL / HIGH（{len(unfixed_actionable)} 件）</summary>",
            "",
            *vuln_rows(unfixed_actionable),
            "",
            "</details>",
        ]

    lines += [
        "",
        f"除外設定: `.devcontainer/.trivyignore.yaml`（{ignores} 件）。"
        "リスク受容で除外する場合は `statement` と `expired_at` を必ず記載すること。",
    ]
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--image", required=True, metavar="PATH", help="trivy image --format json の出力")
    parser.add_argument("--config", metavar="PATH", help="trivy config --format json の出力")
    parser.add_argument("--ignorefile", metavar="PATH", help="件数表示用の .trivyignore.yaml")
    parser.add_argument("--summary", metavar="PATH", help="Markdown の出力先")
    parser.add_argument("--title", default="DevContainer 脆弱性スキャン結果")
    parser.add_argument("--remedy", metavar="NAME", help="全件の対処方法を bump スクリプトの依存名に固定する")
    args = parser.parse_args()

    image_json = json.loads(Path(args.image).read_text())
    config_json = json.loads(Path(args.config).read_text()) if args.config else {}
    findings = load_findings(image_json, args.remedy)
    misconfigs = load_misconfigs(config_json)
    config_targets = [r.get("Target", "") for r in config_json.get("Results") or []]
    report = render(image_json, findings, misconfigs, count_ignores(args.ignorefile), args.title, config_targets)

    if args.summary:
        Path(args.summary).write_text(report)
    else:
        print(report)

    fixable = [f for f in findings if f.fixed]
    counts = {
        "fixable_critical": sum(1 for f in fixable if f.severity == "CRITICAL"),
        "fixable_high": sum(1 for f in fixable if f.severity == "HIGH"),
        "misconfig": len(misconfigs),
        "misconfig_critical": sum(1 for m in misconfigs if m.get("Severity") == "CRITICAL"),
        "total": len(findings),
        "fingerprint": fingerprint(findings),
    }
    print(" ".join(f"{k}={v}" for k, v in counts.items()), file=sys.stderr)
    if gh_out := os.environ.get("GITHUB_OUTPUT"):
        with open(gh_out, "a") as f:
            for k, v in counts.items():
                print(f"{k}={v}", file=f)
    return 0


if __name__ == "__main__":
    sys.exit(main())

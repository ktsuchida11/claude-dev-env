#!/usr/bin/env python3
"""DevContainer dependency auto-bump.

.devcontainer/Dockerfile / mcp-servers.json / docker-compose*.yml / README.md で
pin している依存を「公開から COOLDOWN_DAYS 日以上経過した最新安定版」へ更新する。

- バージョンは上げる方向にのみ更新する（手動でクールダウン例外を適用した版を戻さない）
- SHA256 を ARG に直書きしている依存は、実ファイルをダウンロードして SHA256 を計算し、
  公式 checksums が提供されていれば照合してから書き込む（不一致ならその依存は更新しない）
- 依存ごとに独立して処理し、失敗した依存はスキップしてサマリーに記録する
- APT 署名鍵の fingerprint は自動更新せず、変化を検知したら警告のみ出す

Usage:
  python3 .github/scripts/devcontainer-version-bump.py                    # apply
  python3 .github/scripts/devcontainer-version-bump.py --dry-run          # 変更内容のみ表示
  python3 .github/scripts/devcontainer-version-bump.py --only serena rtk  # 指定した依存のみ
  python3 .github/scripts/devcontainer-version-bump.py --summary out.md   # PR 本文用 Markdown を出力
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import traceback
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path
from typing import Callable

COOLDOWN_DAYS = 7
USER_AGENT = "devcontainer-version-bump"
STABLE = re.compile(r"^v?(\d+(?:\.\d+)+)$")

# メジャーバージョンを固定する依存（理由は Dockerfile / README のコメント参照）
MAJOR_PINS = {
    "rtk": 0,  # 1.0 以降はデフォルトバイナリに BUSL-1.1 (rtk-engine) を含むため
    "serena": 1,  # 2.0 以降は GPL 化・REPL 既定化で MCP ツール構成が変わるため
    "typescript": 6,  # 7 (ネイティブ版) は tsserver.js 非同梱で typescript-language-server が動かないため
    "maven": 3,  # ダウンロード URL が maven-3/ 配下のため
}

REPO_ROOT = Path(__file__).resolve().parents[2]
DOCKERFILE = REPO_ROOT / ".devcontainer" / "Dockerfile"
MCP_SERVERS_JSON = REPO_ROOT / ".devcontainer" / "mcp-servers.json"
README = REPO_ROOT / "README.md"
COMPOSE_FILES = [REPO_ROOT / "docker-compose.yml", REPO_ROOT / "docker-compose-without-litellm.yml"]

NOW = datetime.now(timezone.utc)
BOUNDARY = NOW - timedelta(days=COOLDOWN_DAYS)

WARNINGS: list[str] = []


class BumpError(Exception):
    pass


@dataclass
class Change:
    name: str
    old: str
    new: str
    notes: list[str] = field(default_factory=list)


# --------------------------------------------------------------------------- #
# HTTP / version helpers
# --------------------------------------------------------------------------- #


def http(url: str, *, method: str = "GET", headers: dict | None = None) -> tuple[bytes, dict]:
    h = {"User-Agent": USER_AGENT}
    if url.startswith("https://api.github.com/") and os.environ.get("GITHUB_TOKEN"):
        h["Authorization"] = f"Bearer {os.environ['GITHUB_TOKEN']}"
    h.update(headers or {})
    req = urllib.request.Request(url, method=method, headers=h)
    with urllib.request.urlopen(req, timeout=300) as resp:
        return resp.read(), {k.lower(): v for k, v in resp.headers.items()}


def get_json(url: str, headers: dict | None = None):
    return json.loads(http(url, headers=headers)[0])


def get_text(url: str) -> str:
    return http(url)[0].decode()


def exists(url: str) -> bool:
    try:
        http(url, method="HEAD")
        return True
    except urllib.error.HTTPError:
        return False


def sha256_of(url: str) -> str:
    return hashlib.sha256(http(url)[0]).hexdigest()


def official_sha(sums_text: str, filename: str) -> str | None:
    for line in sums_text.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[-1].lstrip("*") == filename:
            return parts[0].lower()
    return None


def vtuple(v: str) -> tuple[int, ...]:
    return tuple(int(x) for x in v.lstrip("v").split("."))


def is_stable(v: str) -> bool:
    return bool(STABLE.match(v))


def newer(new: str, cur: str) -> bool:
    return vtuple(new) > vtuple(cur)


def parse_iso(ts: str) -> datetime:
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def eligible(ts: datetime) -> bool:
    return ts <= BOUNDARY


def day(ts: datetime) -> str:
    return ts.strftime("%Y-%m-%d")


# --------------------------------------------------------------------------- #
# Release sources
# --------------------------------------------------------------------------- #


@dataclass
class Release:
    version: str
    tag: str
    date: datetime
    assets: list[str]


def gh_latest(repo: str, major: int | None = None) -> Release:
    rels = get_json(f"https://api.github.com/repos/{repo}/releases?per_page=100")
    cands = []
    for r in rels:
        if r["draft"] or r["prerelease"] or not r.get("published_at"):
            continue
        m = STABLE.match(r["tag_name"])
        if not m:
            continue
        v = m.group(1)
        if major is not None and vtuple(v)[0] != major:
            continue
        d = parse_iso(r["published_at"])
        if eligible(d):
            cands.append(Release(v, r["tag_name"], d, [a["name"] for a in r["assets"]]))
    if not cands:
        raise BumpError(f"{repo}: no stable release satisfies cooldown (major={major})")
    return max(cands, key=lambda c: vtuple(c.version))


def npm_latest(pkg: str, major: int | None = None) -> tuple[str, datetime]:
    meta = get_json(f"https://registry.npmjs.org/{pkg.replace('/', '%2F')}")
    cands = []
    for v in meta["versions"]:
        if not is_stable(v) or v not in meta["time"]:
            continue
        if major is not None and vtuple(v)[0] != major:
            continue
        d = parse_iso(meta["time"][v])
        if eligible(d):
            cands.append((v, d))
    if not cands:
        raise BumpError(f"npm {pkg}: no stable version satisfies cooldown (major={major})")
    return max(cands, key=lambda c: vtuple(c[0]))


def pypi_latest(pkg: str) -> tuple[str, datetime]:
    meta = get_json(f"https://pypi.org/pypi/{pkg}/json")
    cands = []
    for v, files in meta["releases"].items():
        if not is_stable(v) or not files or any(f.get("yanked") for f in files):
            continue
        d = min(parse_iso(f["upload_time_iso_8601"]) for f in files)
        if eligible(d):
            cands.append((v, d))
    if not cands:
        raise BumpError(f"pypi {pkg}: no stable version satisfies cooldown")
    return max(cands, key=lambda c: vtuple(c[0]))


def docker_hub_digest(repo: str, tag: str) -> str:
    token = get_json(
        f"https://auth.docker.io/token?service=registry.docker.io&scope=repository:{repo}:pull"
    )["token"]
    accept = ", ".join(
        [
            "application/vnd.oci.image.index.v1+json",
            "application/vnd.docker.distribution.manifest.list.v2+json",
            "application/vnd.oci.image.manifest.v1+json",
            "application/vnd.docker.distribution.manifest.v2+json",
        ]
    )
    try:
        _, h = http(
            f"https://registry-1.docker.io/v2/{repo}/manifests/{tag}",
            method="HEAD",
            headers={"Authorization": f"Bearer {token}", "Accept": accept},
        )
    except urllib.error.HTTPError as e:
        raise BumpError(f"docker {repo}:{tag}: manifest not available ({e.code})") from e
    return h["docker-content-digest"]


def gh_download(repo: str, tag: str, asset: str) -> str:
    return f"https://github.com/{repo}/releases/download/{tag}/{asset}"


# --------------------------------------------------------------------------- #
# File editing
# --------------------------------------------------------------------------- #


class Files:
    def __init__(self) -> None:
        self.orig: dict[Path, str] = {}
        self.cur: dict[Path, str] = {}

    def read(self, p: Path) -> str:
        if p not in self.cur:
            self.orig[p] = self.cur[p] = p.read_text()
        return self.cur[p]

    def write(self, p: Path, text: str) -> None:
        self.read(p)
        self.cur[p] = text

    def changed(self) -> list[Path]:
        return [p for p, t in self.cur.items() if t != self.orig[p]]

    def flush(self) -> None:
        for p in self.changed():
            p.write_text(self.cur[p])


def get_arg(text: str, name: str) -> str:
    m = re.search(rf"^ARG {name}=(.*)$", text, re.M)
    if not m:
        raise BumpError(f"ARG {name} not found in Dockerfile")
    return m.group(1).strip()


def set_arg(text: str, name: str, value: str) -> str:
    new, n = re.subn(rf"^ARG {name}=.*$", f"ARG {name}={value}", text, flags=re.M)
    if n != 1:
        raise BumpError(f"ARG {name}: expected exactly 1 occurrence, found {n}")
    return new


def sub_required(pattern: str, repl: str, text: str, what: str) -> str:
    new, n = re.subn(pattern, repl, text, flags=re.M)
    if n == 0:
        raise BumpError(f"{what}: pattern not found")
    return new


# --------------------------------------------------------------------------- #
# Components
# --------------------------------------------------------------------------- #


def bump_node(files: Files) -> Change | None:
    """Node ベースイメージ。同一メジャー内で更新し、新しい LTS メジャーは警告のみ。"""
    df = files.read(DOCKERFILE)
    m = re.search(r"^FROM node:(\d+\.\d+\.\d+)-([a-z-]+)@(sha256:[0-9a-f]{64})$", df, re.M)
    if not m:
        raise BumpError("FROM node:<ver>-<variant>@sha256:<digest> not found")
    cur, variant, _ = m.groups()
    major = vtuple(cur)[0]
    index = get_json("https://nodejs.org/dist/index.json")

    lts_majors = sorted({vtuple(e["version"])[0] for e in index if e.get("lts")})
    if lts_majors and lts_majors[-1] > major:
        WARNINGS.append(
            f"Node.js {lts_majors[-1]} が LTS になっています（現在 {major}）。メジャー更新は手動で検討してください。"
        )

    # セキュリティリリースは公式の告知・署名付きで配布されるため、クールダウンの例外とする
    cands = []
    for e in index:
        v = e["version"].lstrip("v")
        if vtuple(v)[0] != major:
            continue
        d = datetime.fromisoformat(e["date"]).replace(tzinfo=timezone.utc)
        if eligible(d) or e.get("security"):
            cands.append((v, d, bool(e.get("security"))))
    if not cands:
        return None
    v, d, security = max(cands, key=lambda c: vtuple(c[0]))
    if not newer(v, cur):
        return None
    digest = docker_hub_digest("library/node", f"{v}-{variant}")
    df = sub_required(
        r"^FROM node:\d+\.\d+\.\d+-[a-z-]+@sha256:[0-9a-f]{64}$",
        f"FROM node:{v}-{variant}@{digest}",
        df,
        "FROM node",
    )
    files.write(DOCKERFILE, df)
    notes = [f"released {day(d)}", f"digest `{digest[:19]}…`"]
    if security:
        notes.append("セキュリティリリースのためクールダウン例外")
    return Change("node (base image)", cur, v, notes)


def github_binary(
    name: str,
    repo: str,
    ver_arg: str,
    assets: dict[str, str],
    sums: str | None = None,
    major: int | None = None,
    extra_check: Callable[[Release], None] | None = None,
) -> Callable[[Files], Change | None]:
    """GitHub Release のバイナリを SHA256 ARG で pin している依存。

    assets: {SHA256 を書き込む ARG 名: アセット名テンプレート ({v} = バージョン)}
    sums:   公式 checksums ファイル名テンプレート（無ければ None）
    """

    def bump(files: Files) -> Change | None:
        df = files.read(DOCKERFILE)
        cur = get_arg(df, ver_arg)
        rel = gh_latest(repo, major)
        if not newer(rel.version, cur):
            return None
        sums_text = None
        if sums:
            sums_name = sums.format(v=rel.version)
            if sums_name not in rel.assets:
                raise BumpError(f"{name}: checksums asset {sums_name} missing in {rel.tag}")
            sums_text = get_text(gh_download(repo, rel.tag, sums_name))
        shas = {}
        for sha_arg, tmpl in assets.items():
            asset = tmpl.format(v=rel.version)
            if asset not in rel.assets:
                raise BumpError(f"{name}: asset {asset} missing in {rel.tag}")
            h = sha256_of(gh_download(repo, rel.tag, asset))
            if sums_text is not None:
                off = official_sha(sums_text, asset)
                if off != h:
                    raise BumpError(f"{name}: SHA256 mismatch for {asset} (computed {h}, official {off})")
            shas[sha_arg] = h
        if extra_check:
            extra_check(rel)
        df = set_arg(df, ver_arg, rel.version)
        for sha_arg, h in shas.items():
            df = set_arg(df, sha_arg, h)
        files.write(DOCKERFILE, df)
        verified = "公式 checksums と照合済み" if sums else "公式 checksums 無し（取得時の SHA256 を固定）"
        return Change(name, cur, rel.version, [f"released {day(rel.date)}", verified])

    return bump


def rtk_license_check(rel: Release) -> None:
    raw = f"https://raw.githubusercontent.com/rtk-ai/rtk/{rel.tag}/"
    if "Apache License" not in get_text(raw + "LICENSE")[:500]:
        raise BumpError(f"rtk {rel.tag}: LICENSE is not Apache-2.0")
    cargo = get_text(raw + "Cargo.toml")
    m = re.search(r'^license\s*=\s*"([^"]+)"', cargo, re.M)
    if not m or m.group(1) != "Apache-2.0":
        raise BumpError(f"rtk {rel.tag}: Cargo.toml license is {m.group(1) if m else 'missing'}")
    if exists(raw + "engine/LICENSE"):
        raise BumpError(f"rtk {rel.tag}: BUSL-licensed engine/ is present")


def version_only(name: str, repo: str, ver_arg: str, check: Callable[[Release], None] | None = None):
    """署名検証などをビルド時に行うため、バージョンのみ更新する依存。"""

    def bump(files: Files) -> Change | None:
        df = files.read(DOCKERFILE)
        cur = get_arg(df, ver_arg)
        rel = gh_latest(repo)
        if not newer(rel.version, cur):
            return None
        if check:
            check(rel)
        files.write(DOCKERFILE, set_arg(df, ver_arg, rel.version))
        return Change(name, cur, rel.version, [f"released {day(rel.date)}"])

    return bump


def terraform_check(rel: Release) -> None:
    base = f"https://releases.hashicorp.com/terraform/{rel.version}/terraform_{rel.version}_SHA256SUMS"
    if not exists(base) or not exists(base + ".sig"):
        raise BumpError(f"terraform {rel.version}: SHA256SUMS / .sig not published")


def bump_ssm(files: Files) -> Change | None:
    df = files.read(DOCKERFILE)
    cur = get_arg(df, "SSM_PLUGIN_VERSION")
    rel = gh_latest("aws/session-manager-plugin")
    if not newer(rel.version, cur):
        return None
    for arch, d in (("AMD64", "ubuntu_64bit"), ("ARM64", "ubuntu_arm64")):
        url = f"https://s3.amazonaws.com/session-manager-downloads/plugin/{rel.version}/{d}/session-manager-plugin.deb"
        if not exists(url + ".sig"):
            raise BumpError(f"session-manager-plugin {rel.version}: {d} signature not published")
        df = set_arg(df, f"SSM_PLUGIN_SHA256_{arch}", sha256_of(url))
    files.write(DOCKERFILE, set_arg(df, "SSM_PLUGIN_VERSION", rel.version))
    return Change("session-manager-plugin", cur, rel.version, [f"released {day(rel.date)}", "PGP 署名はビルド時に検証"])


def bump_maven(files: Files) -> Change | None:
    df = files.read(DOCKERFILE)
    cur = get_arg(df, "MAVEN_VERSION")
    xml = get_text("https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/maven-metadata.xml")
    vers = sorted(
        {v for v in re.findall(r"<version>([^<]+)</version>", xml) if is_stable(v) and vtuple(v)[0] == MAJOR_PINS["maven"]},
        key=vtuple,
        reverse=True,
    )
    for v in vers[:5]:
        if not newer(v, cur):
            return None
        url = f"https://archive.apache.org/dist/maven/maven-3/{v}/binaries/apache-maven-{v}-bin.tar.gz"
        try:
            _, h = http(url, method="HEAD")
        except urllib.error.HTTPError:
            continue
        d = parsedate_to_datetime(h["last-modified"])
        if eligible(d) and exists(url + ".sha512"):
            files.write(DOCKERFILE, set_arg(df, "MAVEN_VERSION", v))
            return Change("maven", cur, v, [f"released {day(d)}"])
    return None


def bump_gradle(files: Files) -> Change | None:
    df = files.read(DOCKERFILE)
    cur = get_arg(df, "GRADLE_VERSION")
    cands = []
    for e in get_json("https://services.gradle.org/versions/all"):
        if e.get("snapshot") or e.get("nightly") or e.get("releaseNightly") or e.get("broken"):
            continue
        if e.get("rcFor") or e.get("milestoneFor") or not is_stable(e["version"]):
            continue
        d = datetime.strptime(e["buildTime"], "%Y%m%d%H%M%S%z")
        if eligible(d):
            cands.append((e["version"], d))
    if not cands:
        raise BumpError("gradle: no release satisfies cooldown")
    v, d = max(cands, key=lambda c: vtuple(c[0]))
    if not newer(v, cur):
        return None
    if not exists(f"https://services.gradle.org/distributions/gradle-{v}-bin.zip.sha256"):
        raise BumpError(f"gradle {v}: .sha256 not published")
    files.write(DOCKERFILE, set_arg(df, "GRADLE_VERSION", v))
    return Change("gradle", cur, v, [f"released {day(d)}"])


def bump_jdtls(files: Files) -> Change | None:
    df = files.read(DOCKERFILE)
    cur = get_arg(df, "JDTLS_VERSION")
    base = "https://download.eclipse.org/jdtls/milestones/"
    vers = sorted(set(re.findall(r"(\d+\.\d+\.\d+)/", get_text(base))), key=vtuple, reverse=True)
    if not vers:
        raise BumpError("jdtls: could not parse milestones index")
    for v in vers:
        if not newer(v, cur):
            return None
        m = re.search(rf"jdt-language-server-{re.escape(v)}-(\d{{12}})\.tar\.gz", get_text(f"{base}{v}/"))
        if not m:
            continue
        ts = m.group(1)
        d = datetime.strptime(ts, "%Y%m%d%H%M").replace(tzinfo=timezone.utc)
        if not eligible(d):
            continue
        if not exists(f"{base}{v}/jdt-language-server-{v}-{ts}.tar.gz.sha256"):
            raise BumpError(f"jdtls {v}: .sha256 not published")
        df = set_arg(df, "JDTLS_VERSION", v)
        files.write(DOCKERFILE, set_arg(df, "JDTLS_TIMESTAMP", ts))
        return Change("jdtls", cur, v, [f"build {ts}"])
    return None


def pypi_arg(name: str, pkg: str, ver_arg: str):
    def bump(files: Files) -> Change | None:
        df = files.read(DOCKERFILE)
        cur = get_arg(df, ver_arg)
        v, d = pypi_latest(pkg)
        if not newer(v, cur):
            return None
        files.write(DOCKERFILE, set_arg(df, ver_arg, v))
        return Change(name, cur, v, [f"released {day(d)}"])

    return bump


def npm_arg(name: str, pkg: str, ver_arg: str, major: int | None = None, mcp: bool = False):
    """npm パッケージ。mcp=True の場合は mcp-servers.json と README の pin も揃える。"""

    def bump(files: Files) -> Change | None:
        df = files.read(DOCKERFILE)
        cur = get_arg(df, ver_arg)
        v, d = npm_latest(pkg, major)
        if not newer(v, cur):
            return None
        files.write(DOCKERFILE, set_arg(df, ver_arg, v))
        if mcp:
            esc = re.escape(pkg)
            js = sub_required(rf'"{esc}@[^"]*"', f'"{pkg}@{v}"', files.read(MCP_SERVERS_JSON), f"mcp-servers.json {pkg}")
            json.loads(js)
            files.write(MCP_SERVERS_JSON, js)
            rd = sub_required(rf"(\| npm `{esc}` \| )`[^`]*`( \|)", rf"\g<1>`{v}`\g<2>", files.read(README), f"README {pkg}")
            rd = re.sub(rf"npx {esc}@\S+ --help", f"npx {pkg}@{v} --help", rd)
            files.write(README, rd)
        return Change(name, cur, v, [f"released {day(d)}"])

    return bump


def bump_serena(files: Files) -> Change | None:
    js = files.read(MCP_SERVERS_JSON)
    m = re.search(r"git\+https://github\.com/oraios/serena@([0-9a-f]{40})", js)
    if not m:
        raise BumpError("serena commit pin not found in mcp-servers.json")
    cur_sha = m.group(1)
    rel = gh_latest("oraios/serena", MAJOR_PINS["serena"])
    sha = get_json(f"https://api.github.com/repos/oraios/serena/commits/{rel.tag}")["sha"]
    if sha == cur_sha:
        return None
    status = get_json(f"https://api.github.com/repos/oraios/serena/compare/{cur_sha}...{sha}")["status"]
    if status in ("behind", "identical"):
        return None
    js = js.replace(cur_sha, sha)
    json.loads(js)
    files.write(MCP_SERVERS_JSON, js)
    rd = files.read(README)
    rd = re.sub(
        r"\| serena \| git `oraios/serena` \| commit `[0-9a-f]+`（[^）]*）\|",
        f"| serena | git `oraios/serena` | commit `{sha}`（{rel.tag} 相当）|",
        rd,
    )
    rd = rd.replace(f"oraios/serena@{cur_sha}", f"oraios/serena@{sha}")
    files.write(README, rd)
    notes = [f"released {day(rel.date)}", f"commit `{sha[:12]}`"]
    if status == "diverged":
        notes.append("現在の pin と履歴が分岐しているため要確認")
    return Change("serena (MCP)", cur_sha[:12], rel.tag, notes)


def bump_socket_proxy(files: Files) -> Change | None:
    pat = re.compile(r"tecnativa/docker-socket-proxy:(v[\d.]+)@(sha256:[0-9a-f]{64})")
    cur_tag = None
    for p in COMPOSE_FILES:
        m = pat.search(files.read(p))
        if not m:
            raise BumpError(f"docker-socket-proxy pin not found in {p.name}")
        cur_tag = m.group(1)
    rel = gh_latest("Tecnativa/docker-socket-proxy")
    if not newer(rel.version, cur_tag):
        return None
    digest = docker_hub_digest("tecnativa/docker-socket-proxy", rel.tag)
    for p in COMPOSE_FILES:
        text = pat.sub(f"tecnativa/docker-socket-proxy:{rel.tag}@{digest}", files.read(p))
        files.write(p, text.replace(f"docker-socket-proxy:{cur_tag}", f"docker-socket-proxy:{rel.tag}"))
    return Change("docker-socket-proxy", cur_tag, rel.tag, [f"released {day(rel.date)}", f"digest `{digest[:19]}…`"])


def check_apt_keys(files: Files) -> None:
    """APT 署名鍵の fingerprint 変化を検知する（自動更新はしない）。"""
    if not shutil.which("gpg"):
        WARNINGS.append("gpg が無いため APT 署名鍵の fingerprint チェックをスキップしました。")
        return None
    df = files.read(DOCKERFILE)
    keys = {
        "DOCKER_GPG_FINGERPRINT": "https://download.docker.com/linux/debian/gpg",
        "ADOPTIUM_GPG_FINGERPRINT": "https://packages.adoptium.net/artifactory/api/gpg/key/public",
    }
    with tempfile.TemporaryDirectory() as home:
        for arg, url in keys.items():
            expected = get_arg(df, arg)
            path = Path(home) / "key.asc"
            path.write_bytes(http(url)[0])
            out = subprocess.run(
                ["gpg", "--homedir", home, "--show-keys", "--with-colons", str(path)],
                capture_output=True, text=True, check=True,
            ).stdout
            pubs = [l for l in out.splitlines() if l.startswith("pub:")]
            fprs = [l.split(":")[9] for l in out.splitlines() if l.startswith("fpr:")]
            if len(pubs) != 1 or not fprs or fprs[0] != expected:
                WARNINGS.append(
                    f"`{arg}`: 公開鍵が変化しています（keys={len(pubs)}, fpr={fprs[0] if fprs else 'none'}）。"
                    "鍵ローテーションの公式告知を確認のうえ手動で更新してください。"
                )
    return None


COMPONENTS: list[tuple[str, Callable[[Files], Change | None]]] = [
    ("node", bump_node),
    ("terraform", version_only("terraform", "hashicorp/terraform", "TERRAFORM_VERSION", terraform_check)),
    ("session-manager-plugin", bump_ssm),
    ("tflint", github_binary(
        "tflint", "terraform-linters/tflint", "TFLINT_VERSION",
        {"TFLINT_SHA256_AMD64": "tflint_linux_amd64.zip", "TFLINT_SHA256_ARM64": "tflint_linux_arm64.zip"},
        sums="checksums.txt")),
    ("terraform-docs", github_binary(
        "terraform-docs", "terraform-docs/terraform-docs", "TERRAFORM_DOCS_VERSION",
        {"TERRAFORM_DOCS_SHA256_AMD64": "terraform-docs-v{v}-linux-amd64.tar.gz",
         "TERRAFORM_DOCS_SHA256_ARM64": "terraform-docs-v{v}-linux-arm64.tar.gz"},
        sums="terraform-docs-v{v}.sha256sum")),
    ("trivy", github_binary(
        "trivy", "aquasecurity/trivy", "TRIVY_VERSION",
        {"TRIVY_SHA256_AMD64": "trivy_{v}_Linux-64bit.tar.gz", "TRIVY_SHA256_ARM64": "trivy_{v}_Linux-ARM64.tar.gz"},
        sums="trivy_{v}_checksums.txt")),
    ("gitleaks", github_binary(
        "gitleaks", "gitleaks/gitleaks", "GITLEAKS_VERSION",
        {"GITLEAKS_SHA256_AMD64": "gitleaks_{v}_linux_x64.tar.gz", "GITLEAKS_SHA256_ARM64": "gitleaks_{v}_linux_arm64.tar.gz"},
        sums="gitleaks_{v}_checksums.txt")),
    ("sops", github_binary(
        "sops", "getsops/sops", "SOPS_VERSION",
        {"SOPS_SHA256_AMD64": "sops-v{v}.linux.amd64", "SOPS_SHA256_ARM64": "sops-v{v}.linux.arm64"},
        sums="sops-v{v}.checksums.txt")),
    ("rtk", github_binary(
        "rtk", "rtk-ai/rtk", "RTK_VERSION",
        {"RTK_SHA256_AMD64": "rtk-x86_64-unknown-linux-musl.tar.gz", "RTK_SHA256_ARM64": "rtk-aarch64-unknown-linux-gnu.tar.gz"},
        sums="checksums.txt", major=MAJOR_PINS["rtk"], extra_check=rtk_license_check)),
    ("git-delta", github_binary(
        "git-delta", "dandavison/delta", "GIT_DELTA_VERSION",
        {"GIT_DELTA_SHA256_AMD64": "git-delta_{v}_amd64.deb", "GIT_DELTA_SHA256_ARM64": "git-delta_{v}_arm64.deb"})),
    ("zsh-in-docker", github_binary(
        "zsh-in-docker", "deluan/zsh-in-docker", "ZSH_IN_DOCKER_VERSION",
        {"ZSH_IN_DOCKER_SHA256": "zsh-in-docker.sh"})),
    ("maven", bump_maven),
    ("gradle", bump_gradle),
    ("jdtls", bump_jdtls),
    ("pip", pypi_arg("pip", "pip", "PIP_VERSION")),
    ("uv", pypi_arg("uv", "uv", "UV_VERSION")),
    ("context7-mcp", npm_arg("context7-mcp", "@upstash/context7-mcp", "CONTEXT7_MCP_VERSION", mcp=True)),
    ("playwright-mcp", npm_arg("playwright-mcp", "@playwright/mcp", "PLAYWRIGHT_MCP_VERSION", mcp=True)),
    ("typescript-language-server", npm_arg(
        "typescript-language-server", "typescript-language-server", "TYPESCRIPT_LANGUAGE_SERVER_VERSION")),
    ("typescript", npm_arg("typescript", "typescript", "TYPESCRIPT_VERSION", major=MAJOR_PINS["typescript"])),
    ("pyright", npm_arg("pyright", "pyright", "PYRIGHT_VERSION")),
    ("serena", bump_serena),
    ("docker-socket-proxy", bump_socket_proxy),
    ("apt-keys", check_apt_keys),
]


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #


def render_summary(changes: list[Change], errors: list[tuple[str, str]]) -> str:
    lines = [
        "## Summary",
        "",
        f"DevContainer の依存を、公開から {COOLDOWN_DAYS} 日以上経過した最新安定版へ自動更新"
        f"（基準日: {day(BOUNDARY)} 以前に公開）。",
        "",
    ]
    if changes:
        lines += ["| 依存 | 現在 | 更新後 | 備考 |", "|---|---|---|---|"]
        lines += [f"| {c.name} | `{c.old}` | `{c.new}` | {' / '.join(c.notes)} |" for c in changes]
    else:
        lines.append("更新対象はありません。")
    if WARNINGS:
        lines += ["", "### ⚠️ 要確認", ""] + [f"- {w}" for w in WARNINGS]
    if errors:
        lines += ["", "### ❌ 更新できなかった依存（現行の pin を維持）", ""]
        lines += [f"- **{n}**: {e}" for n, e in errors]
    lines += [
        "",
        "### メジャーバージョン固定中",
        "",
        "rtk 0.x（1.0 以降 BUSL-1.1） / serena 1.x（2.0 以降 GPL・REPL 既定） / "
        "typescript 6.x（7 は tsserver.js 非同梱） / maven 3.x",
    ]
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true", help="ファイルを書き換えずに結果のみ表示")
    parser.add_argument("--only", nargs="+", metavar="NAME", help="対象の依存名（" + ", ".join(n for n, _ in COMPONENTS) + "）")
    parser.add_argument("--summary", metavar="PATH", help="PR 本文用 Markdown の出力先")
    args = parser.parse_args()

    unknown = set(args.only or []) - {n for n, _ in COMPONENTS}
    if unknown:
        parser.error(f"unknown component(s): {', '.join(sorted(unknown))}")

    print(f"Cooldown boundary: {BOUNDARY.isoformat()}", file=sys.stderr)
    files = Files()
    changes: list[Change] = []
    errors: list[tuple[str, str]] = []

    for name, fn in COMPONENTS:
        if args.only and name not in args.only:
            continue
        snapshot = dict(files.cur)
        try:
            change = fn(files)
        except Exception as e:  # noqa: BLE001 — 1 つの依存の失敗で全体を止めない
            files.cur = snapshot
            errors.append((name, str(e)))
            print(f"[error]  {name}: {e}", file=sys.stderr)
            traceback.print_exc(file=sys.stderr)
            continue
        if change:
            changes.append(change)
            print(f"[update] {name}: {change.old} -> {change.new} ({'; '.join(change.notes)})")
        else:
            print(f"[ok]     {name}")

    for w in WARNINGS:
        print(f"[warn]   {w}", file=sys.stderr)

    changed_paths = files.changed()
    for p in changed_paths:
        print(f"{'would update' if args.dry_run else 'updated'}: {p.relative_to(REPO_ROOT)}", file=sys.stderr)
    if not args.dry_run:
        files.flush()

    if args.summary:
        Path(args.summary).write_text(render_summary(changes, errors))

    if gh_out := os.environ.get("GITHUB_OUTPUT"):
        with open(gh_out, "a") as f:
            print(f"changed={'true' if changed_paths and not args.dry_run else 'false'}", file=f)
            print(f"errors={'true' if errors else 'false'}", file=f)
            print(f"updated={', '.join(c.name for c in changes)}", file=f)
    return 0


if __name__ == "__main__":
    sys.exit(main())

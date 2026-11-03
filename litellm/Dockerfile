# ベースイメージを正式リリースのタグ + SHA256 ダイジェストでピン留め（サプライチェーン対策）
# main-latest（開発ブランチのビルド）は使わない。LiteLLM は 2026-03 にサプライチェーン攻撃を受けている。
# GitHub の正式リリース（prerelease / -rc / -dev 以外）に .github/scripts/devcontainer-version-bump.py が
# 7 日クールダウンで追従し、自動更新 PR を作成する。更新時は config.yaml との互換性をリリースノートで確認すること。
# 2026-10-21 に再びリリースパイプラインが侵害され悪性 1.107.0 が公開されたため、自動更新の上限を 1.106.2
# （侵害直前の最後の安全版）にしている（bump スクリプトの MAX_VERSIONS）。
FROM ghcr.io/berriai/litellm:v1.106.2@sha256:7294b90f868c5c38c99b83021c7ba46f9b439e95f8e32964c925c7d2563a03f7

COPY config.yaml /app/config.yaml
COPY --chmod=755 require-master-key.sh /usr/local/bin/require-master-key.sh

EXPOSE 4000

# LITELLM_MASTER_KEY 未設定（= 認証なし）では起動しない。docker/prod_entrypoint.sh はベースイメージの ENTRYPOINT
ENTRYPOINT ["/usr/local/bin/require-master-key.sh", "docker/prod_entrypoint.sh"]
CMD ["--config", "/app/config.yaml", "--port", "4000", "--host", "0.0.0.0"]

# ベースイメージを正式リリースのタグ + SHA256 ダイジェストでピン留め（サプライチェーン対策）
# main-latest（開発ブランチのビルド）は使わない。LiteLLM は 2026-03 にサプライチェーン攻撃を受けている。
# GitHub の正式リリース（prerelease / -rc / -dev 以外）に .github/scripts/devcontainer-version-bump.py が
# 7 日クールダウンで追従し、自動更新 PR を作成する。更新時は config.yaml との互換性をリリースノートで確認すること。
FROM ghcr.io/berriai/litellm:v1.99.4@sha256:475f4ae80a09d769d84c92202e70502abe52a62a760c97e598261c9c8cf8244f

COPY config.yaml /app/config.yaml
COPY --chmod=755 require-master-key.sh /usr/local/bin/require-master-key.sh

EXPOSE 4000

# LITELLM_MASTER_KEY 未設定（= 認証なし）では起動しない。docker/prod_entrypoint.sh はベースイメージの ENTRYPOINT
ENTRYPOINT ["/usr/local/bin/require-master-key.sh", "docker/prod_entrypoint.sh"]
CMD ["--config", "/app/config.yaml", "--port", "4000", "--host", "0.0.0.0"]

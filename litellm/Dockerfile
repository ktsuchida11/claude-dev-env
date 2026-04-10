# ベースイメージを SHA256 ダイジェストでピン留め（サプライチェーン対策）
# 更新時: docker pull ghcr.io/berriai/litellm:main-latest && docker inspect --format='{{index .RepoDigests 0}}' ghcr.io/berriai/litellm:main-latest
FROM ghcr.io/berriai/litellm:main-latest@sha256:7c311546c25e7bb6e8cafede9fcd3d0d622ac636b5c9418befaa32e85dfb0186

COPY config.yaml /app/config.yaml

EXPOSE 4000

CMD ["--config", "/app/config.yaml", "--port", "4000", "--host", "0.0.0.0"]

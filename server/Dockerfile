# --- Stage 1: build the Flutter web app ---------------------------------------
# Pinned to the build platform (the native runner arch, e.g. amd64) regardless
# of the *target* image arch. The compiled web bundle is just static JS/HTML and
# is identical for every CPU arch, so we build it once natively instead of
# recompiling Flutter under slow QEMU emulation for each target platform.
#
# `stable` currently tracks Flutter 3.44.1 (Dart 3.12.1), which satisfies the
# app's SDK constraint. cirruslabs does not publish a pinned 3.44.1 tag.
FROM --platform=$BUILDPLATFORM ghcr.io/cirruslabs/flutter:stable AS webbuild
WORKDIR /app

# Pre-fetch dependencies (better layer caching).
COPY app/pubspec.yaml app/pubspec.lock ./
RUN flutter pub get

# Build: generate drift code, then compile the web release bundle.
# --pwa-strategy=none: the web client is online-only (no offline support), so the
# service worker is pure downside — it pins open tabs to a cached old build after
# a deploy (needing a hard refresh). Disabling it keeps the app always-fresh.
COPY app/ ./
# gen-l10n first: the .arb files arrive with this COPY (pub get above ran before
# them), and build_runner analyzes the library graph — which imports the
# generated AppLocalizations — so it must exist before build_runner runs.
RUN flutter gen-l10n \
    && dart run build_runner build --delete-conflicting-outputs \
    && flutter build web --release --pwa-strategy=none

# --- Stage 2: PocketBase serving the web app ----------------------------------
# Single static binary on a small Alpine base. This stage IS arch-specific (the
# PocketBase binary is per-arch), so it builds once per target platform.
FROM alpine:3.20

ARG PB_VERSION=0.39.1
# TARGETARCH is provided automatically by BuildKit: "amd64" or "arm64",
# which matches PocketBase's release asset naming (linux_amd64 / linux_arm64).
ARG TARGETARCH

RUN apk add --no-cache ca-certificates unzip wget

RUN wget -q "https://github.com/pocketbase/pocketbase/releases/download/v${PB_VERSION}/pocketbase_${PB_VERSION}_linux_${TARGETARCH}.zip" -O /tmp/pb.zip \
    && unzip /tmp/pb.zip -d /pb \
    && rm /tmp/pb.zip

# PocketBase serves static files from ./pb_public (next to the binary), so the
# server root (http://host:8080/) returns the Flutter web app. /api and /_/
# remain the REST API and admin dashboard.
COPY --from=webbuild /app/build/web /pb/pb_public

# Bake the schema migrations and (optional) JS hooks into the image so a fresh
# machine running only the deploy compose file comes up fully configured — no
# repo checkout or bind mounts required. pb_data stays external (a volume).
COPY server/pb_migrations /pb/pb_migrations
COPY server/pb_hooks /pb/pb_hooks

# Entrypoint can bootstrap a superuser from PB_SUPERUSER_EMAIL/PASSWORD env vars
# (see entrypoint.sh) before handing off to the serve CMD below.
COPY server/entrypoint.sh /pb/entrypoint.sh
RUN chmod +x /pb/entrypoint.sh

# OCI metadata (the CI build adds version-specific labels via metadata-action).
LABEL org.opencontainers.image.title="Noteesek" \
      org.opencontainers.image.description="Noteesek — Flutter web app served by a PocketBase backend" \
      org.opencontainers.image.source="https://github.com/Hromad-a/Noteesek" \
      org.opencontainers.image.licenses="MIT"

EXPOSE 8080

# pb_data is provided externally (volume/bind mount). pb_migrations and pb_hooks
# are baked in above but can still be overridden by a bind mount for development.
ENTRYPOINT ["/pb/entrypoint.sh"]
CMD ["/pb/pocketbase", "serve", "--http=0.0.0.0:8080"]

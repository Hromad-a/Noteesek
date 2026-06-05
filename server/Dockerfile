# --- Stage 1: build the Flutter web app ---------------------------------------
FROM ghcr.io/cirruslabs/flutter:3.44.0 AS webbuild
WORKDIR /app

# Pre-fetch dependencies (better layer caching).
COPY app/pubspec.yaml app/pubspec.lock ./
RUN flutter pub get

# Build: generate drift code, then compile the web release bundle.
COPY app/ ./
RUN dart run build_runner build --delete-conflicting-outputs \
    && flutter build web --release

# --- Stage 2: PocketBase serving the web app ----------------------------------
# Single static binary on a small Alpine base.
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
# server root (http://host:8090/) returns the Flutter web app. /api and /_/
# remain the REST API and admin dashboard.
COPY --from=webbuild /app/build/web /pb/pb_public

EXPOSE 8080

# pb_data, pb_migrations and pb_hooks are bind-mounted via docker-compose.
CMD ["/pb/pocketbase", "serve", "--http=0.0.0.0:8080"]

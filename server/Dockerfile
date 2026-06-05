# PocketBase backend for Noteesek.
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

EXPOSE 8080

# pb_data, pb_migrations and pb_hooks are bind-mounted via docker-compose.
CMD ["/pb/pocketbase", "serve", "--http=0.0.0.0:8080"]

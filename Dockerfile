## Build stage — Go DAO HTTP engine
FROM golang:1.22-alpine AS gobuilder
WORKDIR /src
COPY go/ ./
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /out/universe-dao .

## Runtime — shell + python + go binary
FROM alpine:3.20
RUN apk add --no-cache \
      bash \
      coreutils \
      gawk \
      bc \
      jq \
      python3 \
      py3-pip \
      make \
      git \
      curl \
      ca-certificates

WORKDIR /workspace
COPY . /workspace
COPY --from=gobuilder /out/universe-dao /usr/local/bin/universe-dao

ENV LRU_BASE_DIR=/workspace \
    UNIVERSE_BASE_DIR=/workspace \
    PORT=8080

EXPOSE 8080

ENTRYPOINT ["/bin/bash", "-lc"]
CMD ["sh scripts/run_universe.sh --status && universe-dao"]

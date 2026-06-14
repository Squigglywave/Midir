# syntax=docker/dockerfile:1.7

# --- Stage 1: build the Vue frontend ---
FROM node:20-bookworm AS frontend
WORKDIR /src/front
COPY front/package.json front/package-lock.json ./
RUN npm ci
COPY front/ ./
RUN npm run build

# --- Stage 2: build the Go backend ---
FROM golang:1.24-bookworm AS backend
RUN apt-get update \
 && apt-get install -y --no-install-recommends libpcap-dev \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
# Embed the freshly built frontend so the Go binary can serve it.
RUN rm -rf cmd/dilmeterapi/static \
 && mkdir -p cmd/dilmeterapi/static
COPY --from=frontend /src/front/dist/ cmd/dilmeterapi/static/
RUN CGO_ENABLED=1 GOOS=linux go build -ldflags="-s -w" -trimpath \
        -o /out/midir ./cmd/dilmeterapi

# --- Stage 3: minimal runtime ---
FROM debian:bookworm-slim AS runtime
RUN apt-get update \
 && apt-get install -y --no-install-recommends libpcap0.8 ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=backend /out/midir /usr/local/bin/midir
EXPOSE 8030
ENTRYPOINT ["/usr/local/bin/midir"]

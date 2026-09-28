# Stage 1: Build binaries from source
FROM golang:1.22-alpine AS builder

WORKDIR /src

COPY ca.pem /app/ca.pem

# Download dependencies
COPY go.mod go.sum ./
RUN go mod download

# Copy source code
COPY . .

# Build nanomdm and nano2nano static binaries
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -o /app/nanomdm ./cmd/nanomdm
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -o /app/nano2nano ./cmd/nano2nano

# Stage 2: Minimal runtime image
FROM alpine:3.19

RUN apk add --no-cache ca-certificates tzdata

WORKDIR /app

COPY --from=builder /app/nanomdm /app/nanomdm
COPY --from=builder /app/nano2nano /app/nano2nano
COPY ca.pem /app/ca.pem

EXPOSE 8080

ENTRYPOINT ["/app/nanomdm"]


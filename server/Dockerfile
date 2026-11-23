# syntax=docker/dockerfile:1
ARG GO_VERSION=1.27.4
FROM golang:${GO_VERSION}-bookworm AS build
WORKDIR /src
COPY server/go.mod server/go.sum ./
RUN go mod download
COPY server/ ./
RUN CGO_ENABLED=0 go build -o /out/server ./cmd/server

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/server /server
USER nonroot:nonroot
EXPOSE 8080
ENV ER_LISTEN_ADDR=:8080
ENTRYPOINT ["/server"]

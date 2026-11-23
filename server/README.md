# Endless Realm server

Authoritative Go game server (protocol v1). Stack: [`docs/tech/stack.md`](../docs/tech/stack.md).

## Folder layout

```
.
├── Makefile
├── docker-compose.yml          # Postgres (unused by the server yet) + server
├── tools/versions.env          # pinned Go, protoc, protoc-gen-go, godobuf, Postgres
├── proto/v1/protocol.proto     # Hello/Welcome, InputFrame, Snapshot stub
├── data/                       # shared JSON game data (placeholder)
└── server/
    ├── cmd/server/             # process entrypoint
    ├── internal/clock/         # injectable clock (real + fake)
    ├── internal/config/        # --listen, --seed, --multiplier / ER_* env
    ├── internal/instance/      # one in-process room, locked multiplier, 20 Hz tick
    ├── internal/net/           # /healthz and /ws
    └── internal/protocol/v1/   # generated Go (committed)
```

Generated protobuf code is committed. Re-run `make proto` after editing `.proto` files (installs pinned `protoc` and `protoc-gen-go` into `.tools/`).

## Commands

From the repository root (Go **1.27.4** is pinned in `server/go.mod` and `tools/versions.env`):

| Command | What it does |
|---|---|
| `make dev` | `docker compose up --build` — starts pinned Postgres and the game server |
| `make run` | run the server on the host (`:8080` by default) |
| `make test` | `go vet ./...` and `go test ./...` in `server/` |
| `make proto` | regenerate `server/internal/protocol/v1/protocol.pb.go` |

```sh
make test
make run
# health: http://localhost:8080/healthz
# connect: ws://localhost:8080/ws
```

Flags and env (env is the default; flags override):

- `--listen` / `ER_LISTEN_ADDR` (default `:8080`)
- `--seed` / `ER_SEED` (default `1`)
- `--multiplier` / `ER_MULTIPLIER` (default `1.0`, must be in `[0.5, 1.5]`, locked at process start)

The first WebSocket message must be a protobuf `Hello` with `protocol_version = 1`. A mismatch is rejected with a `Reject` frame and the connection is closed.

## Client connection (including Android)

The client's server address **must be configurable** at runtime. `ws://localhost:8080/ws` only works on the same machine as the server. An Android phone on the LAN needs the host's LAN IP, e.g. `ws://192.168.1.10:8080/ws`.

For **dev cleartext `ws://`** on Android, the export must allow cleartext traffic (`usesCleartextTraffic` and/or a network security config that permits the dev server). **Production uses `wss://`.** This skeleton does not terminate TLS.

Client protobuf codegen is **godobuf** at the version pinned in `tools/versions.env` (`GODOBUF_VERSION`). That pin is a note for the client PR; this repo does not install godobuf yet.

## Out of scope (later PRs)

Auth, persistence (Postgres is started only), portal-open API, movement/combat sim, PCG32 pattern fixtures, and godobuf round-trip tests.

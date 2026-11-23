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
    ├── cmd/bot/                # standalone smoke/soak WebSocket client
    ├── internal/bot/           # bot client + CI flag contract
    ├── internal/clock/         # injectable clock (real + fake)
    ├── internal/config/        # --listen, --seed, --multiplier / ER_* env
    ├── internal/instance/      # one in-process room, locked multiplier, 20 Hz tick
    ├── internal/net/           # /healthz and /ws
    └── internal/protocol/v1/   # generated Go (committed)
```

Generated protobuf code is committed. Re-run `make proto` after editing `.proto` files (installs pinned `protoc` and `protoc-gen-go` into `.tools/`). Confirm the tree is clean with `make proto-check`.

## Commands

From the repository root (Go **1.27.4** is pinned in `server/go.mod` and `tools/versions.env`):

| Command | What it does |
|---|---|
| `make dev` | `docker compose --env-file tools/versions.env up --build` — starts pinned Postgres and the game server |
| `make run` | run the server on the host (`:8080` by default) |
| `make test` | `go vet ./...` and `go test -race -count=1 ./...` in `server/` |
| `make proto` | regenerate `server/internal/protocol/v1/protocol.pb.go` |
| `make proto-check` | `make proto` and fail if generated files drifted |
| `make smoke` | compose up, wait for `/healthz`, run `cmd/bot` with the CI smoke flags, compose down |

```sh
make test
make run
# health: http://localhost:8080/healthz
# connect: ws://localhost:8080/ws
```

`make dev` and `make smoke` pass `--env-file tools/versions.env` so compose interpolates the pinned `GO_VERSION` and `POSTGRES_IMAGE`. A raw `docker compose up` still works: the compose file keeps the same values as `:-` defaults.

The server image is distroless, so the compose healthcheck runs `/server -healthcheck`, which probes `http://127.0.0.1:<port>/healthz` and exits 0/1.

Flags and env (env is the default; flags override):

- `--listen` / `ER_LISTEN_ADDR` (default `:8080`)
- `--seed` / `ER_SEED` (default `1`)
- `--multiplier` / `ER_MULTIPLIER` — a decimal (`1.05`, `1.0`) or an integer. Integers **under 10** are decimals (`1` means 1.00); integers **≥ 10** are hundredths (`105` means 1.05). Decimals must already be whole hundredths (within float tolerance); `1.053` is rejected, not rounded. Then `50 ≤ M100 ≤ 150` and `M100 % 5 == 0` (0.05 steps in `[0.5, 1.5]`, per the design doc). The instance stores `M100`. Locked at process start.
- `--healthcheck` — probe `/healthz` on the listen address and exit (compose HEALTHCHECK)

Compose binds Postgres to `127.0.0.1:5432` and the game server to `127.0.0.1:8080`. The Postgres volume is mounted at `/var/lib/postgresql` (required for Postgres 18+ images). If you already ran compose when the volume was mounted at `/var/lib/postgresql/data`, delete the stale volume once with `docker compose down -v` before `make dev` or `make smoke`. The server does not connect to Postgres yet.

The first WebSocket message must be a protobuf `Hello` with `protocol_version = 1`. A mismatch, a text frame, or a garbage binary frame is rejected with a `Reject` frame and the connection is closed.

## Bot contract (`server/cmd/bot`)

Standalone test client used by CI `integration-smoke` / soak and `make smoke`. Build it the way CI does:

```sh
cd server && go build -o er-bot ./cmd/bot
```

Invocation (flags match `.github/workflows/ci.yml` and `soak.yml` on PR #5):

```sh
# smoke (CI): handshake + at least one snapshot, then exit 0
./er-bot -url ws://127.0.0.1:8080/ws -clients=1 -seed=1 -mult=1.0

# soak (CI): stay connected for the duration, then exit 0
./er-bot -url ws://127.0.0.1:8080/ws -clients=8 -seed=1 -mult=1.0 -duration=10m
```

Without Docker, start the server with `make run` and run the smoke command above in another shell.

| Flag | Meaning |
|---|---|
| `-url` | WebSocket URL. CI passes `-url ws://127.0.0.1:8080/ws`. If omitted, `ER_SMOKE_URL` is used; if that is also empty, the default is `ws://127.0.0.1:8080/ws`. |
| `-clients` | Concurrent clients (must be ≥ 1). CI smoke uses `1`. |
| `-seed` | Expected `Welcome.instance_seed`. Exit non-zero on mismatch. CI passes `1`, matching compose `ER_SEED`. |
| `-mult` | Expected level multiplier (same parse rules as the server). Exit non-zero on mismatch. CI passes `1.0`. |
| `-duration` | Soak length, Go duration syntax (e.g. `10m`). If set, the bot exits 0 after this elapses once every client has received a snapshot, ticks have advanced, and `applied_seq` has caught up. If omitted, the bot exits 0 after the first snapshot (smoke). `-h` lists this flag (soak detects it that way). |
| `-stall-timeout` | During a soak, fail if no new snapshot arrives for this long (default `5s`). A 600 ms server pause must not fail the bot. |

The bot exits non-zero on dial failure, handshake failure (`Reject` or missing `Welcome`), seed/multiplier mismatch, if no snapshot arrives within 10s, if snapshots stall for `-stall-timeout` during a soak, or if ticks / `applied_seq` do not advance. One failing client cancels the others. `ER_MULTIPLIER=1.0` and `ER_SEED=1` in compose are the values smoke checks.

## Client connection (including Android)

The client's server address **must be configurable** at runtime. `ws://localhost:8080/ws` only works on the same machine as the server. An Android phone on the LAN needs the host's LAN IP, e.g. `ws://192.168.1.10:8080/ws`.

For **dev cleartext `ws://`** on Android, the export must allow cleartext traffic (`usesCleartextTraffic` and/or a network security config that permits the dev server). **Production uses `wss://`.** This skeleton does not terminate TLS.

Client protobuf codegen is **godobuf** at the version pinned in `tools/versions.env` (`GODOBUF_VERSION`). That pin is a note for the client PR; this repo does not install godobuf yet.

## Out of scope (later PRs)

Auth, persistence (Postgres is started only), portal-open API (`INVALID_MULTIPLIER` on the OpenPortal wire is specified in the design doc; this PR only applies the M100 rules to config and the locked instance value), movement/combat sim, PCG32 pattern fixtures, and godobuf round-trip tests.

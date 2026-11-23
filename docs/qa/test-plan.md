# Endless Realm — QA test plan (v0.1)

**Owner:** QA & Build  
**Applies to:** `main` and every PR into it  
**Stack:** see [docs/tech/stack.md](../tech/stack.md) (Godot 4.7.2-stable + GUT 9.7.1, Go server, Protobuf, Postgres, Docker Compose)

CI lives in [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) (every PR and every push to `main`) and
[`.github/workflows/soak.yml`](../../.github/workflows/soak.yml) (nightly and on demand). Each CI job checks for its inputs first.
If an input isn't in the repo yet, the job prints `skipped: <path> not present yet` and passes. Once the input lands, the job runs
for real and can fail.

## Test layers

| Layer | What it proves | How it runs | CI job | Inputs it waits for |
|---|---|---|---|---|
| Shared data | `data/` JSON parses and matches its JSON Schema | `check-jsonschema` against `data/schema/<name>.schema.json` (by file stem, then parent folder); plus `make data-validate` if defined | `data-validate` | `data/schema/` |
| Wire codegen | Go and GDScript (godobuf) code generated from `proto/` is committed and current | `make proto`, then `git diff --exit-code` (untracked files count too) | `proto-codegen-check` | `proto/`, `server/go.mod`, `Makefile` with a `proto` target |
| Server unit | Go code vets, builds and passes tests under the race detector | `go vet ./...`, `go build ./...`, `go test -race ./...` with the Go version from `server/go.mod` | `server-build-test` | `server/go.mod` |
| Client unit | GDScript sim and client code pass GUT | Godot 4.7.2 headless `--import`, then GUT 9.7.1 with JUnit output. **Fails if the XML is missing or reports 0 tests.** | `client-tests` | `client/project.godot` |
| Golden fixtures parity | Go and GDScript give the same results for the same fixture: pattern positions at tick N within epsilon (PCG32, fixed seeding), and Protobuf round-trips byte for byte | `make fixtures-parity` (runs both sides against `fixtures/`) | `fixtures-parity` | `fixtures/`, `server/go.mod`, `client/project.godot`, `Makefile` with a `fixtures-parity` target |
| Client–server integration smoke | The compose stack comes up healthy and one bot client completes a session | `docker compose up --wait`, then `bot -clients=1 -seed=1 -mult=1.0`, then `docker compose down -v`. Logs are uploaded on failure. | `integration-smoke` | a compose file at the repo root, `server/cmd/bot` |
| Multi-client soak | The server stays up and responsive with 8–32 concurrent clients for about 10 minutes | Nightly runs use 8 and 32 clients; manual runs choose 8–32 clients and the duration | `soak` (**not required**) | same as the integration smoke |
| Export / playable build | The client exports for every target, and the Android APK installs and launches | Godot 4.7.2 export templates, `--export-debug` per preset; Android uses JDK 17, the Android SDK and a debug keystore generated in CI | `export-builds (linux)`, `export-builds (windows)`, `export-builds (android)` | `client/project.godot`, `client/export_presets.cfg` with presets `Linux`, `Windows Desktop`, `Android` |

### Conventions engineers should follow

- **Determinism:** tests that touch randomness use the seed and multiplier hooks (`-seed`, `-mult`) and the sim tick index, never wall-clock time.
- **GUT:** tests go under `client/test/` (or a `client/.gutconfig.json` that points at them). The editor's Android SDK path and keystore are set by CI and are never committed.
- **Fixtures:** each golden fixture is one JSON input plus its expected output in `fixtures/`, read by both the Go and GDScript tests. Changing the expected output needs a design or engineering note in the PR saying why.
- **Makefile targets CI calls when they exist:** `proto`, `tools` (installs the pinned protoc, protoc-gen-go and godobuf), `fixtures-parity`, `data-validate`.
- **No secrets in the repo.** Signing keys for release builds will come from repository secrets later. Debug builds use a throwaway keystore made in CI.

### Android playable check (manual, per release candidate)

1. Download the `endless-realm-android-<sha>` artifact from the PR's CI run.
2. Install it with `adb install -r endless-realm.apk` on one physical device (Android 10 or later) and one emulator.
3. Launch the app, reach the title screen, connect to a local compose server (set the address in-game; the debug build allows cleartext `ws://`), log in, move, fire, and open a portal at multipliers 0.5, 1.0 and 1.5.
4. Background the app, bring it back, and check that the session either resumes or shows a clear reconnect message.
5. Record the device, OS version, SHA and result in the PR.

The Linux and Windows artifacts get the same smoke check on desktop: launch, log in, move, fire, open a portal and quit cleanly.

## Required checks on `main`

Once the job for a check has real inputs on `main`, add it under branch protection as a required status check:

- `data-validate`
- `proto-codegen-check`
- `server-build-test`
- `client-tests`
- `fixtures-parity`
- `integration-smoke`
- `export-builds (android)`

`export-builds (linux)` and `export-builds (windows)` run on every PR and upload artifacts. They can be added later. `soak` is never a required check.

## Merge rule

1. All required checks are green **on the PR's current head SHA**.
2. QA approval is a review comment that names that exact SHA, for example `QA APPROVED at 1a2b3c4…`. (All agents post as the same GitHub user, so GitHub's own "Approve" state can't be used. The SHA-pinned comment is the gate.)
3. **Any new push to the PR resets the approval.** QA re-reviews the new head and posts a new SHA-pinned approval before merge.
4. Nobody merges with an admin override or bypasses branch protection.
5. Squash-merge into `main`. CI runs again on the push to `main`, and a red `main` is fixed before anything else merges.

## Out of scope for this public repo

This repository is public. Security, abuse and exploit test cases, along with their findings, are tracked privately and are not described here, in issues or in PR comments.

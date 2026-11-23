# Endless Realm — common commands. Versions are pinned in tools/versions.env.
include tools/versions.env
export

GO        ?= go
GOTOOLCHAIN := go$(GO_VERSION)
export GOTOOLCHAIN
ROOT      := $(abspath .)
TOOLS     := $(ROOT)/.tools
PROTOC    := $(TOOLS)/bin/protoc
PATH      := $(TOOLS)/bin:$(PATH)
export PATH

# Interpolation of ${GO_VERSION} / ${POSTGRES_IMAGE} in docker-compose.yml.
# Raw `docker compose up` still works: the compose file keeps `:-` defaults.
COMPOSE   ?= docker compose --env-file tools/versions.env

.PHONY: dev test proto proto-check run vet smoke wait-healthz client-test fixtures-parity data-validate sync-client-data check-client-data

# Starts Postgres and the game server. Connect the Godot client to
# ws://localhost:8080/ws (configure the address; do not hard-code localhost
# if testing on an Android device).
dev:
	$(COMPOSE) up --build

# CI runs `make test` with GOFLAGS='-timeout=3m -count=1' (PR #5). Go applies
# only the flags each subcommand knows, so `go vet` ignores those test flags.
# -count=1 is also on the test command line so a local `make test` without
# GOFLAGS does not reuse cached results; a duplicate -count=1 is harmless.
# Do not add -timeout here: a command-line timeout would override CI's GOFLAGS.
vet:
	cd server && $(GO) vet ./...

test: vet
	cd server && $(GO) test -race -count=1 ./...

run:
	cd server && $(GO) run ./cmd/server

# Headless GUT 9.7.1 for the Godot client. Installs the addon if missing.
# Override the binary with GODOT=/path/to/godot if it is not on PATH.
GODOT ?= godot
client-test:
	@if [ ! -f client/project.godot ]; then echo "client/project.godot not found" >&2; exit 1; fi
	@if [ ! -f client/addons/gut/gut_cmdln.gd ]; then \
		.github/scripts/install-gut.sh client $(GUT_VERSION) $(GUT_SHA256); \
	fi
	@mkdir -p client/test_results
	$(GODOT) --headless --path client --import
	$(GODOT) --headless --path client -s addons/gut/gut_cmdln.gd \
		-gdir=res://tests -ginclude_subdirs -gexit \
		-gjunit_xml_file=res://test_results/junit.xml
	python3 .github/scripts/check-junit.py client/test_results/junit.xml

# Keep a packed copy of the shared data pack under client/data (res://data)
# so editor and export load the same files. data/ remains the source of truth.
CLIENT_DATA_FILES := enemies.json patterns.json classes.json loot.json scaling.json

sync-client-data:
	@mkdir -p client/data
	@cp -f $(addprefix data/,$(CLIENT_DATA_FILES)) client/data/

check-client-data:
	@for f in $(CLIENT_DATA_FILES); do 		if [ ! -f "client/data/$$f" ] || ! cmp -s "data/$$f" "client/data/$$f"; then 			echo "client/data/$$f is out of sync with data/$$f. Run 'make sync-client-data' and commit the copy." >&2; 			exit 1; 		fi; 	done

# Shared data pack: JSON parse + schema checks (requires check-jsonschema),
# pattern-reference and damage_key checks (content-v0.1 §5), and packed-copy sync.
data-validate:
	python3 .github/scripts/validate-data.py
	@$(MAKE) check-client-data

# Go and GDScript must agree on fixtures/pcg32 and fixtures/patterns.
# Runs server/internal/sim tests (including the golden fixtures) and the
# full GUT suite, which includes test_pcg32.gd, test_pattern.gd, and test_combat.gd.
fixtures-parity:
	cd server && $(GO) test -race -count=1 ./internal/sim
	@$(MAKE) client-test

# Regenerates server/internal/protocol/v1/protocol.pb.go from proto/v1.
# Generated Go is committed so `go test` does not require protoc.
proto: $(PROTOC) $(TOOLS)/bin/protoc-gen-go
	$(PROTOC) -I proto \
		--go_out=server \
		--go_opt=module=github.com/Karyu42/endless-realm/server \
		proto/v1/protocol.proto

# Fails if `make proto` would change or add committed files.
proto-check: proto
	@if [ -n "$$(git status --porcelain --untracked-files=all -- proto server/internal/protocol/v1)" ]; then \
		echo "make proto changed or added files. Run 'make proto' and commit the result." >&2; \
		git status --porcelain --untracked-files=all -- proto server/internal/protocol/v1; \
		git diff -- proto server/internal/protocol/v1; \
		exit 1; \
	fi
	@git diff --exit-code -- proto server/internal/protocol/v1

# Compose up, wait until /healthz is ready, run the CI smoke bot, then down.
# Requires Docker. Without Docker, run `make run` and in another shell:
#   cd server && go run ./cmd/bot -url ws://127.0.0.1:8080/ws -clients=1 -seed=1 -mult=1.0
smoke:
	$(COMPOSE) up --build --detach --wait --wait-timeout 300
	@status=0; \
	$(MAKE) wait-healthz || status=$$?; \
	if [ $$status -eq 0 ]; then \
		mkdir -p $(TOOLS); \
		(cd server && $(GO) build -o $(TOOLS)/er-bot ./cmd/bot) || status=$$?; \
	fi; \
	if [ $$status -eq 0 ]; then \
		$(TOOLS)/er-bot -url ws://127.0.0.1:8080/ws -clients=1 -seed=1 -mult=1.0 || status=$$?; \
	fi; \
	$(COMPOSE) down --remove-orphans || true; \
	exit $$status

wait-healthz:
	@i=0; \
	while [ $$i -lt 50 ]; do \
		if curl -sf http://127.0.0.1:8080/healthz >/dev/null 2>&1; then exit 0; fi; \
		if python3 -c 'import urllib.request,sys; sys.exit(0 if urllib.request.urlopen("http://127.0.0.1:8080/healthz", timeout=1).status==200 else 1)' 2>/dev/null; then exit 0; fi; \
		i=$$((i+1)); sleep 0.1; \
	done; \
	echo "server /healthz did not become ready" >&2; exit 1

$(PROTOC):
	@mkdir -p $(TOOLS)
	@os=$$(uname -s | tr '[:upper:]' '[:lower:]'); \
	arch=$$(uname -m); \
	case $$arch in x86_64) arch=x86_64 ;; aarch64|arm64) arch=aarch_64 ;; *) echo "unsupported arch $$arch"; exit 1 ;; esac; \
	case $$os in linux) os=linux ;; darwin) os=osx ;; *) echo "unsupported os $$os"; exit 1 ;; esac; \
	curl -fsSL -o /tmp/protoc.zip \
	  "https://github.com/protocolbuffers/protobuf/releases/download/v$(PROTOC_VERSION)/protoc-$(PROTOC_VERSION)-$$os-$$arch.zip"; \
	unzip -o /tmp/protoc.zip -d $(TOOLS) >/dev/null; \
	rm -f /tmp/protoc.zip

$(TOOLS)/bin/protoc-gen-go:
	@mkdir -p $(TOOLS)/bin
	GOBIN=$(TOOLS)/bin $(GO) install google.golang.org/protobuf/cmd/protoc-gen-go@$(PROTOC_GEN_GO_VERSION)

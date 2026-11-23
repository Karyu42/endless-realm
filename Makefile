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

.PHONY: dev test proto run vet

# Starts Postgres and the game server. Connect the Godot client to
# ws://localhost:8080/ws (configure the address; do not hard-code localhost
# if testing on an Android device).
dev:
	docker compose up --build

vet:
	cd server && $(GO) vet ./...

test: vet
	cd server && $(GO) test ./...

run:
	cd server && $(GO) run ./cmd/server

# Regenerates server/internal/protocol/v1/protocol.pb.go from proto/v1.
# Generated Go is committed so `go test` does not require protoc.
proto: $(PROTOC) $(TOOLS)/bin/protoc-gen-go
	$(PROTOC) -I proto \
		--go_out=server \
		--go_opt=module=github.com/Karyu42/endless-realm/server \
		proto/v1/protocol.proto

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

module github.com/Karyu42/endless-realm/server

// Toolchain is Go 1.27.4 (GO_VERSION in tools/versions.env; Makefile sets GOTOOLCHAIN).
go 1.27.4

require (
	github.com/coder/websocket v1.8.14
	google.golang.org/protobuf v1.36.12
)

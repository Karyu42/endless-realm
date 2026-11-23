// Package net serves /healthz and the /ws WebSocket endpoint.
package net

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
	"google.golang.org/protobuf/proto"

	"github.com/Karyu42/endless-realm/server/internal/instance"
	protocolv1 "github.com/Karyu42/endless-realm/server/internal/protocol/v1"
)

const handshakeTimeout = 5 * time.Second

// Server is the HTTP + WebSocket front door to one in-process instance.
type Server struct {
	inst    *instance.Instance
	http    *http.Server
	nextID  atomic.Uint32
	writeTO time.Duration
}

func New(inst *instance.Instance) *Server {
	s := &Server{inst: inst, writeTO: 5 * time.Second}
	s.nextID.Store(1)
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealthz)
	mux.HandleFunc("/ws", s.handleWS)
	s.http = &http.Server{Handler: mux}
	return s
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.http.Handler.ServeHTTP(w, r)
}

func (s *Server) ListenAndServe(addr string) error {
	s.http.Addr = addr
	log.Printf("health: http://localhost%s/healthz", advertised(addr))
	log.Printf("connect: ws://localhost%s/ws", advertised(addr))
	return s.http.ListenAndServe()
}

func (s *Server) Shutdown(ctx context.Context) error {
	return s.http.Shutdown(ctx)
}

func advertised(addr string) string {
	if len(addr) > 0 && addr[0] == ':' {
		return addr
	}
	return addr
}

func (s *Server) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok\n"))
}

func (s *Server) handleWS(w http.ResponseWriter, r *http.Request) {
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		// Any origin for local/dev Godot clients; tighten before production.
		InsecureSkipVerify: true,
	})
	if err != nil {
		log.Printf("ws accept: %v", err)
		return
	}
	defer conn.Close(websocket.StatusNormalClosure, "")
	conn.SetReadLimit(64 << 10)

	ctx := r.Context()
	if err := s.session(ctx, conn); err != nil {
		log.Printf("ws session: %v", err)
	}
}

func (s *Server) session(ctx context.Context, conn *websocket.Conn) error {
	hctx, cancel := context.WithTimeout(ctx, handshakeTimeout)
	playerID, err := s.handshake(hctx, conn)
	cancel()
	if err != nil {
		return err
	}

	snaps, unsub := s.inst.Subscribe()
	defer unsub()

	var writeMu sync.Mutex
	write := func(ctx context.Context, msg *protocolv1.ServerMessage) error {
		body, err := proto.Marshal(msg)
		if err != nil {
			return err
		}
		wctx, cancel := context.WithTimeout(ctx, s.writeTO)
		defer cancel()
		writeMu.Lock()
		defer writeMu.Unlock()
		return conn.Write(wctx, websocket.MessageBinary, body)
	}

	errCh := make(chan error, 2)
	go func() {
		for {
			select {
			case <-ctx.Done():
				errCh <- ctx.Err()
				return
			case snap, ok := <-snaps:
				if !ok {
					errCh <- nil
					return
				}
				if err := write(ctx, snapshotMsg(snap)); err != nil {
					errCh <- err
					return
				}
			}
		}
	}()
	go func() {
		for {
			typ, data, err := conn.Read(ctx)
			if err != nil {
				errCh <- err
				return
			}
			if typ != websocket.MessageBinary {
				errCh <- fmt.Errorf("expected binary frame")
				return
			}
			var cm protocolv1.ClientMessage
			if err := proto.Unmarshal(data, &cm); err != nil {
				errCh <- fmt.Errorf("decode client message: %w", err)
				return
			}
			in := cm.GetInput()
			if in == nil {
				errCh <- fmt.Errorf("expected input frame after handshake")
				return
			}
			s.inst.SubmitInput(instance.Input{
				PlayerID: playerID,
				Seq:      in.GetSeq(),
				MoveX:    float64(in.GetMoveX()),
				MoveY:    float64(in.GetMoveY()),
				Aim:      float64(in.GetAim()),
				FireHeld: in.GetFireHeld(),
			})
		}
	}()
	return <-errCh
}

func (s *Server) handshake(ctx context.Context, conn *websocket.Conn) (uint32, error) {
	typ, data, err := conn.Read(ctx)
	if err != nil {
		return 0, fmt.Errorf("read hello: %w", err)
	}
	if typ != websocket.MessageBinary {
		return 0, s.reject(ctx, conn, 0, "expected a binary Hello frame")
	}
	var cm protocolv1.ClientMessage
	if err := proto.Unmarshal(data, &cm); err != nil {
		return 0, s.reject(ctx, conn, 0, "invalid Hello protobuf")
	}
	hello := cm.GetHello()
	if hello == nil {
		return 0, s.reject(ctx, conn, 0, "first message must be Hello")
	}
	if hello.GetProtocolVersion() != instance.ProtocolVersion {
		reason := fmt.Sprintf("protocol version mismatch: client=%d server=%d", hello.GetProtocolVersion(), instance.ProtocolVersion)
		return 0, s.reject(ctx, conn, hello.GetProtocolVersion(), reason)
	}

	id := s.nextID.Add(1) - 1
	welcome := &protocolv1.ServerMessage{
		Payload: &protocolv1.ServerMessage_Welcome{Welcome: &protocolv1.Welcome{
			ProtocolVersion: instance.ProtocolVersion,
			PlayerId:        id,
			TickHz:          instance.TickRate,
			InstanceSeed:    s.inst.Seed(),
			Multiplier:      float32(s.inst.Multiplier()),
		}},
	}
	body, err := proto.Marshal(welcome)
	if err != nil {
		return 0, err
	}
	if err := conn.Write(ctx, websocket.MessageBinary, body); err != nil {
		return 0, err
	}
	return id, nil
}

func (s *Server) reject(ctx context.Context, conn *websocket.Conn, clientVer uint32, reason string) error {
	msg := &protocolv1.ServerMessage{
		Payload: &protocolv1.ServerMessage_Reject{Reject: &protocolv1.Reject{
			ServerProtocolVersion: instance.ProtocolVersion,
			ClientProtocolVersion: clientVer,
			Reason:                reason,
		}},
	}
	if body, err := proto.Marshal(msg); err == nil {
		_ = conn.Write(ctx, websocket.MessageBinary, body)
	}
	_ = conn.Close(websocket.StatusPolicyViolation, reason)
	return fmt.Errorf("%s", reason)
}

func snapshotMsg(snap instance.Snapshot) *protocolv1.ServerMessage {
	out := &protocolv1.Snapshot{Tick: snap.Tick}
	for _, p := range snap.Players {
		out.Players = append(out.Players, &protocolv1.PlayerStub{Id: p.ID, AppliedSeq: p.AppliedSeq})
	}
	return &protocolv1.ServerMessage{Payload: &protocolv1.ServerMessage_Snapshot{Snapshot: out}}
}

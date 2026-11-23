// Package net serves /healthz, /metrics and the /ws WebSocket endpoint.
package net

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
	"google.golang.org/protobuf/proto"

	"github.com/Karyu42/endless-realm/server/internal/instance"
	protocolv1 "github.com/Karyu42/endless-realm/server/internal/protocol/v1"
)

const handshakeTimeout = 5 * time.Second

// Server is the HTTP + WebSocket front door to the in-process instance hub.
type Server struct {
	hub     *instance.Hub
	http    *http.Server
	nextID  atomic.Uint32
	writeTO time.Duration
	baseCtx context.Context
	cancel  context.CancelFunc
}

func New(inst *instance.Instance) *Server {
	return NewContext(context.Background(), inst)
}

// NewContext is like New but derives session and portal-instance lifetimes
// from ctx. Sessions are cancelled when ctx is cancelled, when
// Shutdown/Close is called, or when the WebSocket disconnects.
func NewContext(ctx context.Context, inst *instance.Instance) *Server {
	ctx, cancel := context.WithCancel(ctx)
	s := &Server{hub: instance.NewHub(ctx, inst), writeTO: 5 * time.Second, baseCtx: ctx, cancel: cancel}
	s.nextID.Store(1)
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealthz)
	mux.HandleFunc("/metrics", s.handleMetrics)
	mux.HandleFunc("/ws", s.handleWS)
	s.http = &http.Server{Handler: mux, BaseContext: func(net.Listener) context.Context { return s.baseCtx }}
	return s
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.http.Handler.ServeHTTP(w, r)
}

func (s *Server) ListenAndServe(addr string) error {
	s.http.Addr = addr
	health, connect := listenURLs(addr)
	log.Printf("health: %s", health)
	log.Printf("metrics: %s", strings.Replace(health, "/healthz", "/metrics", 1))
	log.Printf("connect: %s", connect)
	return s.http.ListenAndServe()
}

func (s *Server) Shutdown(ctx context.Context) error {
	s.Close()
	return s.http.Shutdown(ctx)
}

// Close cancels the server context, ending all sessions and portal Run loops.
func (s *Server) Close() {
	if s.cancel != nil {
		s.cancel()
	}
}

// listenURLs builds the advertised health and WebSocket URLs for a listen
// address. Wildcard or empty hosts are shown as localhost so a bind of
// "127.0.0.1:8080" is not concatenated onto the word "localhost".
func listenURLs(addr string) (health, connect string) {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		if strings.HasPrefix(addr, ":") {
			host, port = "", strings.TrimPrefix(addr, ":")
		} else {
			host, port = "localhost", "8080"
		}
	}
	if host == "" || host == "0.0.0.0" || host == "::" || host == "[::]" {
		host = "localhost"
	}
	hp := net.JoinHostPort(host, port)
	return "http://" + hp + "/healthz", "ws://" + hp + "/ws"
}

// ProbeHealthz GETs /healthz on the listen address. Wildcard binds are
// probed on 127.0.0.1 so this works from a distroless HEALTHCHECK.
func ProbeHealthz(ctx context.Context, listenAddr string) error {
	health, _ := listenURLs(listenAddr)
	health = strings.Replace(health, "://localhost", "://127.0.0.1", 1)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, health, nil)
	if err != nil {
		return err
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return fmt.Errorf("%s: status %d", health, res.StatusCode)
	}
	return nil
}

func (s *Server) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok\n"))
}

func (s *Server) handleMetrics(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	fmt.Fprintf(w, "# HELP er_skipped_ticks Ticks skipped by the 20 Hz catch-up cap.\n")
	fmt.Fprintf(w, "# TYPE er_skipped_ticks counter\n")
	fmt.Fprintf(w, "er_skipped_ticks %d\n", s.hub.SkippedTicks())
	fmt.Fprintf(w, "# HELP er_instances Current in-process instances (default plus open portals).\n")
	fmt.Fprintf(w, "# TYPE er_instances gauge\n")
	fmt.Fprintf(w, "er_instances %d\n", s.hub.InstanceCount())
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

	sessCtx, cancel := context.WithCancel(s.baseCtx)
	defer cancel()
	stop := context.AfterFunc(r.Context(), cancel)
	defer stop()

	if err := s.session(sessCtx, conn); err != nil {
		log.Printf("ws session: %v", err)
	}
}

type snapSwitch struct {
	mu    sync.Mutex
	ch    <-chan instance.Snapshot
	unsub func()
	ping  chan struct{}
}

func newSnapSwitch() *snapSwitch {
	return &snapSwitch{ping: make(chan struct{}, 1)}
}

func (sw *snapSwitch) set(ch <-chan instance.Snapshot, unsub func()) {
	sw.mu.Lock()
	if sw.unsub != nil {
		sw.unsub()
	}
	sw.ch = ch
	sw.unsub = unsub
	sw.mu.Unlock()
	select {
	case sw.ping <- struct{}{}:
	default:
	}
}

func (sw *snapSwitch) current() (<-chan instance.Snapshot, <-chan struct{}) {
	sw.mu.Lock()
	defer sw.mu.Unlock()
	return sw.ch, sw.ping
}

func (sw *snapSwitch) close() {
	sw.mu.Lock()
	defer sw.mu.Unlock()
	if sw.unsub != nil {
		sw.unsub()
		sw.unsub = nil
	}
}

func (s *Server) session(ctx context.Context, conn *websocket.Conn) error {
	hctx, cancel := context.WithTimeout(ctx, handshakeTimeout)
	if _, err := s.readHello(hctx, conn); err != nil {
		cancel()
		return err
	}
	cancel()

	id, err := s.allocPlayer()
	if err != nil {
		return err
	}
	cur, info := s.hub.Arrive(id)
	instID := info.ID
	defer func() { s.hub.Depart(id, instID) }()

	sw := newSnapSwitch()
	defer sw.close()
	snaps, unsub := cur.Subscribe()
	sw.set(snaps, unsub)

	if err := s.writeWelcome(ctx, conn, id, cur, instID); err != nil {
		return err
	}

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
			ch, ping := sw.current()
			select {
			case <-ctx.Done():
				errCh <- ctx.Err()
				return
			case <-ping:
				continue
			case snap, ok := <-ch:
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
			newInst, newID, out, err := s.handleClient(id, &instID, &cm)
			if err != nil {
				if werr := write(ctx, errorMsg(err)); werr != nil {
					errCh <- werr
					return
				}
				continue
			}
			if newInst != nil {
				ch, unsub := newInst.Subscribe()
				sw.set(ch, unsub)
			}
			if out != nil {
				if werr := write(ctx, out); werr != nil {
					errCh <- werr
					return
				}
			}
			_ = newID
		}
	}()
	err = <-errCh
	return err
}

func (s *Server) allocPlayer() (uint32, error) {
	return s.nextID.Add(1) - 1, nil
}

func (s *Server) handleClient(player uint32, instID *uint64, cm *protocolv1.ClientMessage) (*instance.Instance, uint64, *protocolv1.ServerMessage, error) {
	switch p := cm.Payload.(type) {
	case *protocolv1.ClientMessage_Input:
		in := p.Input
		inst, ok := s.hub.Get(*instID)
		if !ok {
			return nil, *instID, nil, instance.ErrNotFound
		}
		inst.SubmitInput(instance.Input{
			PlayerID: player,
			Seq:      in.GetSeq(),
			MoveX:    float64(in.GetMoveX()),
			MoveY:    float64(in.GetMoveY()),
			Aim:      float64(in.GetAim()),
			FireHeld: in.GetFireHeld(),
		})
		return nil, *instID, nil, nil
	case *protocolv1.ClientMessage_OpenPortal:
		inst, info, err := s.hub.OpenAndJoin(p.OpenPortal.GetM100(), player, *instID)
		if err != nil {
			return nil, *instID, nil, err
		}
		*instID = info.ID
		return inst, info.ID, &protocolv1.ServerMessage{
			Payload: &protocolv1.ServerMessage_OpenPortalOk{OpenPortalOk: &protocolv1.OpenPortalOk{
				InstanceId: info.ID, M100: uint32(info.M100), Seed: info.Seed,
			}},
		}, nil
	case *protocolv1.ClientMessage_JoinInstance:
		want := p.JoinInstance.GetInstanceId()
		inst, info, err := s.hub.Join(want, player, *instID)
		if err != nil {
			return nil, *instID, nil, err
		}
		changed := info.ID != *instID
		*instID = info.ID
		out := &protocolv1.ServerMessage{
			Payload: &protocolv1.ServerMessage_JoinInstanceOk{JoinInstanceOk: &protocolv1.JoinInstanceOk{
				InstanceId: info.ID, M100: uint32(info.M100), Seed: info.Seed,
			}},
		}
		if changed {
			return inst, info.ID, out, nil
		}
		return nil, info.ID, out, nil
	case *protocolv1.ClientMessage_LeaveInstance:
		inst, info, err := s.hub.Join(instance.DefaultInstanceID, player, *instID)
		if err != nil {
			return nil, *instID, nil, err
		}
		changed := info.ID != *instID
		*instID = info.ID
		out := &protocolv1.ServerMessage{
			Payload: &protocolv1.ServerMessage_JoinInstanceOk{JoinInstanceOk: &protocolv1.JoinInstanceOk{
				InstanceId: info.ID, M100: uint32(info.M100), Seed: info.Seed,
			}},
		}
		if changed {
			return inst, info.ID, out, nil
		}
		return nil, info.ID, out, nil
	case *protocolv1.ClientMessage_ListInstances:
		list := s.hub.List()
		msg := &protocolv1.InstanceList{}
		for _, inf := range list {
			msg.Instances = append(msg.Instances, &protocolv1.InstanceInfo{
				InstanceId:  inf.ID,
				M100:        uint32(inf.M100),
				Seed:        inf.Seed,
				PlayerCount: uint32(inf.Players),
				IsDefault:   inf.Default,
			})
		}
		return nil, *instID, &protocolv1.ServerMessage{
			Payload: &protocolv1.ServerMessage_InstanceList{InstanceList: msg},
		}, nil
	default:
		return nil, *instID, nil, fmt.Errorf("expected input or portal command after handshake")
	}
}

func (s *Server) readHello(ctx context.Context, conn *websocket.Conn) (*protocolv1.Hello, error) {
	typ, data, err := conn.Read(ctx)
	if err != nil {
		return nil, fmt.Errorf("read hello: %w", err)
	}
	if typ != websocket.MessageBinary {
		return nil, s.reject(ctx, conn, 0, "expected a binary Hello frame")
	}
	var cm protocolv1.ClientMessage
	if err := proto.Unmarshal(data, &cm); err != nil {
		return nil, s.reject(ctx, conn, 0, "invalid Hello protobuf")
	}
	hello := cm.GetHello()
	if hello == nil {
		return nil, s.reject(ctx, conn, 0, "first message must be Hello")
	}
	if hello.GetProtocolVersion() != instance.ProtocolVersion {
		reason := fmt.Sprintf("protocol version mismatch: client=%d server=%d", hello.GetProtocolVersion(), instance.ProtocolVersion)
		return nil, s.reject(ctx, conn, hello.GetProtocolVersion(), reason)
	}
	return hello, nil
}

func (s *Server) writeWelcome(ctx context.Context, conn *websocket.Conn, id uint32, inst *instance.Instance, instID uint64) error {
	welcome := &protocolv1.ServerMessage{
		Payload: &protocolv1.ServerMessage_Welcome{Welcome: &protocolv1.Welcome{
			ProtocolVersion: instance.ProtocolVersion,
			PlayerId:        id,
			TickHz:          instance.TickRate,
			InstanceSeed:    inst.Seed(),
			Multiplier:      float32(inst.Multiplier()),
			InstanceId:      instID,
			M100:            uint32(inst.MultiplierHundredths()),
		}},
	}
	body, err := proto.Marshal(welcome)
	if err != nil {
		return err
	}
	return conn.Write(ctx, websocket.MessageBinary, body)
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

func errorMsg(err error) *protocolv1.ServerMessage {
	code := protocolv1.ErrorCode_ERROR_CODE_UNSPECIFIED
	reason := err.Error()
	switch {
	case errors.Is(err, instance.ErrAlreadyIn):
		code = protocolv1.ErrorCode_ALREADY_IN_INSTANCE
	case errors.Is(err, instance.ErrNotFound):
		code = protocolv1.ErrorCode_INSTANCE_NOT_FOUND
	case errors.Is(err, instance.ErrFull):
		code = protocolv1.ErrorCode_INSTANCE_FULL
	case errors.Is(err, instance.ErrOpenLimit):
		code = protocolv1.ErrorCode_OPEN_PORTAL_LIMIT
	default:
		// Validation errors from ValidateM100U32 are not sentinels.
		if strings.Contains(reason, "hundredths") || strings.Contains(reason, "multiplier") {
			code = protocolv1.ErrorCode_INVALID_MULTIPLIER
		}
	}
	return &protocolv1.ServerMessage{
		Payload: &protocolv1.ServerMessage_Error{Error: &protocolv1.Error{Code: code, Reason: reason}},
	}
}

func snapshotMsg(snap instance.Snapshot) *protocolv1.ServerMessage {
	out := &protocolv1.Snapshot{Tick: snap.Tick}
	for _, p := range snap.Players {
		out.Players = append(out.Players, &protocolv1.PlayerStub{Id: p.ID, AppliedSeq: p.AppliedSeq})
	}
	return &protocolv1.ServerMessage{Payload: &protocolv1.ServerMessage_Snapshot{Snapshot: out}}
}

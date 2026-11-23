package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/Karyu42/endless-realm/server/internal/clock"
	"github.com/Karyu42/endless-realm/server/internal/config"
	"github.com/Karyu42/endless-realm/server/internal/instance"
	ernet "github.com/Karyu42/endless-realm/server/internal/net"
)

func main() {
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("er-server: ")

	cfg, err := config.Parse(os.Args[1:])
	if err != nil {
		log.Fatal(err)
	}

	inst, err := instance.New(cfg.Seed, cfg.Multiplier, clock.Real{})
	if err != nil {
		log.Fatal(err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go inst.Run(ctx)

	srv := ernet.New(inst)
	go func() {
		<-ctx.Done()
		shut, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(shut)
	}()

	log.Printf("instance seed=%d multiplier=%g tick=%dHz", inst.Seed(), inst.Multiplier(), instance.TickRate)
	if err := srv.ListenAndServe(cfg.ListenAddr); err != nil && ctx.Err() == nil {
		log.Fatal(err)
	}
}

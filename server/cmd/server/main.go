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

	if cfg.Healthcheck {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		if err := ernet.ProbeHealthz(ctx, cfg.ListenAddr); err != nil {
			log.Fatal(err)
		}
		return
	}

	inst, err := instance.New(cfg.Seed, cfg.MultiplierHundredths, clock.Real{})
	if err != nil {
		log.Fatal(err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go inst.Run(ctx)

	srv := ernet.NewContext(ctx, inst)
	go func() {
		<-ctx.Done()
		shut, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(shut)
	}()

	log.Printf("instance seed=%d multiplier=%s (%d hundredths) max-players=%d tick=%dHz", inst.Seed(), instance.FormatMultiplier(inst.MultiplierHundredths()), inst.MultiplierHundredths(), cfg.MaxPlayers, instance.TickRate)
	if err := srv.ListenAndServe(cfg.ListenAddr); err != nil && ctx.Err() == nil {
		log.Fatal(err)
	}
}

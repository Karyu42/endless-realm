package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/Karyu42/endless-realm/server/internal/bot"
)

func main() {
	cfg, err := bot.ParseFlags(os.Args[1:])
	if err != nil {
		if err == flag.ErrHelp {
			os.Exit(0)
		}
		fmt.Fprintf(os.Stderr, "er-bot: %v\n", err)
		os.Exit(2)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := bot.Run(ctx, cfg); err != nil {
		fmt.Fprintf(os.Stderr, "er-bot: %v\n", err)
		os.Exit(1)
	}
}

// Package config loads listen address, instance seed, and multiplier from
// flags and environment variables.
package config

import (
	"flag"
	"fmt"
	"os"
	"strconv"

	"github.com/Karyu42/endless-realm/server/internal/instance"
)

const (
	DefaultListenAddr           = ":8080"
	DefaultSeed                 = uint64(1)
	DefaultMultiplierHundredths = 100
	DefaultMaxPlayers           = instance.DefaultMaxPlayers

	EnvListenAddr = "ER_LISTEN_ADDR"
	EnvSeed       = "ER_SEED"
	EnvMultiplier = "ER_MULTIPLIER"
	EnvMaxPlayers = "ER_MAX_PLAYERS"
)

type Config struct {
	ListenAddr           string
	Seed                 uint64
	MultiplierHundredths int
	MaxPlayers           int
	Healthcheck          bool
}

func Default() Config {
	return Config{
		ListenAddr:           DefaultListenAddr,
		Seed:                 DefaultSeed,
		MultiplierHundredths: DefaultMultiplierHundredths,
		MaxPlayers:           DefaultMaxPlayers,
	}
}

// FromEnv returns defaults overlaid with ER_* environment variables.
// ER_MULTIPLIER accepts either a decimal ("1.05") or integer hundredths ("105").
func FromEnv() (Config, error) {
	cfg := Default()
	if v := os.Getenv(EnvListenAddr); v != "" {
		cfg.ListenAddr = v
	}
	if v := os.Getenv(EnvSeed); v != "" {
		n, err := strconv.ParseUint(v, 10, 64)
		if err != nil {
			return Config{}, fmt.Errorf("%s: %w", EnvSeed, err)
		}
		cfg.Seed = n
	}
	if v := os.Getenv(EnvMultiplier); v != "" {
		m100, err := instance.ParseMultiplier(v)
		if err != nil {
			return Config{}, fmt.Errorf("%s: %w", EnvMultiplier, err)
		}
		cfg.MultiplierHundredths = m100
	}
	if v := os.Getenv(EnvMaxPlayers); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil {
			return Config{}, fmt.Errorf("%s: %w", EnvMaxPlayers, err)
		}
		if err := instance.ValidateMaxPlayers(n); err != nil {
			return Config{}, fmt.Errorf("%s: %w", EnvMaxPlayers, err)
		}
		cfg.MaxPlayers = n
	}
	return cfg, nil
}

// Parse overlays environment values with command-line flags.
func Parse(args []string) (Config, error) {
	cfg, err := FromEnv()
	if err != nil {
		return Config{}, err
	}
	fs := flag.NewFlagSet("server", flag.ContinueOnError)
	listen := fs.String("listen", cfg.ListenAddr, "listen address (env "+EnvListenAddr+")")
	seed := fs.Uint64("seed", cfg.Seed, "instance seed (env "+EnvSeed+")")
	mult := fs.String("multiplier", instance.FormatMultiplier(cfg.MultiplierHundredths),
		"instance level multiplier as a decimal (1.05) or hundredths (105); v0.1 is [0.5, 1.5] on 0.05 steps (env "+EnvMultiplier+")")
	maxPlayers := fs.Int("max-players", cfg.MaxPlayers,
		"lobby max players, 1–50, default 50 (env "+EnvMaxPlayers+"); the Godot host enforces the cap")
	healthcheck := fs.Bool("healthcheck", false, "probe /healthz on the listen address and exit (for compose/distroless HEALTHCHECK)")
	if err := fs.Parse(args); err != nil {
		return Config{}, err
	}
	m100, err := instance.ParseMultiplier(*mult)
	if err != nil {
		return Config{}, err
	}
	if err := instance.ValidateMaxPlayers(*maxPlayers); err != nil {
		return Config{}, fmt.Errorf("-max-players: %w", err)
	}
	cfg.ListenAddr = *listen
	cfg.Seed = *seed
	cfg.MultiplierHundredths = m100
	cfg.MaxPlayers = *maxPlayers
	cfg.Healthcheck = *healthcheck
	return cfg, nil
}

// Package config loads listen address, instance seed, and multiplier from
// flags and environment variables.
package config

import (
	"flag"
	"fmt"
	"os"
	"strconv"
)

const (
	DefaultListenAddr = ":8080"
	DefaultSeed       = uint64(1)
	DefaultMultiplier = 1.0

	EnvListenAddr = "ER_LISTEN_ADDR"
	EnvSeed       = "ER_SEED"
	EnvMultiplier = "ER_MULTIPLIER"
)

type Config struct {
	ListenAddr string
	Seed       uint64
	Multiplier float64
}

func Default() Config {
	return Config{
		ListenAddr: DefaultListenAddr,
		Seed:       DefaultSeed,
		Multiplier: DefaultMultiplier,
	}
}

// FromEnv returns defaults overlaid with ER_* environment variables.
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
		n, err := strconv.ParseFloat(v, 64)
		if err != nil {
			return Config{}, fmt.Errorf("%s: %w", EnvMultiplier, err)
		}
		cfg.Multiplier = n
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
	mult := fs.Float64("multiplier", cfg.Multiplier, "instance level multiplier in [0.5, 1.5] (env "+EnvMultiplier+")")
	if err := fs.Parse(args); err != nil {
		return Config{}, err
	}
	cfg.ListenAddr = *listen
	cfg.Seed = *seed
	cfg.Multiplier = *mult
	return cfg, nil
}

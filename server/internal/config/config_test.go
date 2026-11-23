package config

import (
	"testing"
)

func TestParseMultiplierFlagDecimalAndHundredths(t *testing.T) {
	t.Setenv(EnvListenAddr, "")
	t.Setenv(EnvSeed, "")
	t.Setenv(EnvMultiplier, "")

	cfg, err := Parse([]string{"-multiplier", "1.05", "-seed", "9"})
	if err != nil {
		t.Fatal(err)
	}
	if cfg.MultiplierHundredths != 105 {
		t.Fatalf("got %d, want 105", cfg.MultiplierHundredths)
	}
	if cfg.Seed != 9 {
		t.Fatalf("seed %d, want 9", cfg.Seed)
	}

	cfg, err = Parse([]string{"-multiplier", "125"})
	if err != nil {
		t.Fatal(err)
	}
	if cfg.MultiplierHundredths != 125 {
		t.Fatalf("got %d, want 125", cfg.MultiplierHundredths)
	}
}

func TestParseRejectsOffStepAndOutOfRange(t *testing.T) {
	t.Setenv(EnvMultiplier, "")
	for _, arg := range []string{"0.45", "1.55", "1.07", "45", "107"} {
		if _, err := Parse([]string{"-multiplier", arg}); err == nil {
			t.Fatalf("multiplier %s: want error", arg)
		}
	}
}

func TestFromEnvParsesDecimalAndHundredths(t *testing.T) {
	t.Setenv(EnvMultiplier, "1.50")
	cfg, err := FromEnv()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.MultiplierHundredths != 150 {
		t.Fatalf("got %d, want 150", cfg.MultiplierHundredths)
	}

	t.Setenv(EnvMultiplier, "50")
	cfg, err = FromEnv()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.MultiplierHundredths != 50 {
		t.Fatalf("got %d, want 50", cfg.MultiplierHundredths)
	}
}

func TestParseHealthcheckFlag(t *testing.T) {
	t.Setenv(EnvMultiplier, "")
	cfg, err := Parse([]string{"-healthcheck", "-listen", ":9090"})
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.Healthcheck {
		t.Fatal("expected healthcheck true")
	}
	if cfg.ListenAddr != ":9090" {
		t.Fatalf("listen %q", cfg.ListenAddr)
	}
	if cfg.MultiplierHundredths != DefaultMultiplierHundredths {
		t.Fatalf("default hundredths %d", cfg.MultiplierHundredths)
	}
}

func TestParseDefaultMultiplier(t *testing.T) {
	t.Setenv(EnvMultiplier, "")
	cfg, err := Parse(nil)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.MultiplierHundredths != 100 {
		t.Fatalf("default %d, want 100", cfg.MultiplierHundredths)
	}
}

func TestParseBareOneAndRejectOffHundredth(t *testing.T) {
	t.Setenv(EnvMultiplier, "")
	cfg, err := Parse([]string{"-multiplier", "1"})
	if err != nil {
		t.Fatal(err)
	}
	if cfg.MultiplierHundredths != 100 {
		t.Fatalf("bare 1 -> %d, want 100", cfg.MultiplierHundredths)
	}
	if _, err := Parse([]string{"-multiplier", "1.053"}); err == nil {
		t.Fatal("1.053: want error")
	}
}

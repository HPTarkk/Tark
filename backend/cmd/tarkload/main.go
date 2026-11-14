// Command tarkload fills a development database with made-up accounts and
// drives the API the way the app does, to measure what a server can carry.
//
//	tarkload seed -users 200000     fill an EMPTY development database
//	tarkload run  -rps 100,200,400  drive a running server, one step per rate
//
// It reads the same environment as tarkd and refuses to do anything unless
// TARK_ENV=development: seeding writes accounts straight into the database,
// and a load run is an attack on any server that is not yours to test. See
// LOADTEST.md for how to use it and how to read the numbers.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/HPTarkk/Tark/backend/internal/config"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: tarkload <seed|run> [flags]")
		os.Exit(2)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	var err error
	switch os.Args[1] {
	case "seed":
		err = seedCmd(ctx, os.Args[2:])
	case "run":
		err = runCmd(ctx, os.Args[2:])
	default:
		err = fmt.Errorf("unknown command %q", os.Args[1])
	}
	if err != nil && !errors.Is(err, flag.ErrHelp) {
		fmt.Fprintln(os.Stderr, "tarkload:", err)
		os.Exit(1)
	}
}

// loadConfig reads tarkd's configuration and insists on development.
func loadConfig() (*config.Config, error) {
	cfg, err := config.Load()
	if err != nil {
		return nil, err
	}
	if !cfg.Development() {
		return nil, errors.New("refusing to run: TARK_ENV is not development")
	}
	return cfg, nil
}

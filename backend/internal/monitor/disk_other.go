//go:build !linux

package monitor

import "errors"

// The server runs Linux; elsewhere (local development) the disk check is
// reported as unavailable rather than guessed.
func diskSpace(string) (uint64, uint64, error) {
	return 0, 0, errors.New("disk check is only supported on Linux")
}

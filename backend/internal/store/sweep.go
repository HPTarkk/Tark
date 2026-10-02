package store

import (
	"context"
	"errors"
	"fmt"
	"time"
)

// sweepBatch bounds how many rows one DELETE removes, so a large backlog is
// cleared in many short statements instead of one that outlives the
// statement timeout and holds locks the whole time.
const sweepBatch = 5000

// SweepRule names a table and the WHERE condition of its expired rows. Both
// are compile-time constants written in this repository, never user input.
type SweepRule struct {
	Table string
	Where string
	Args  []any
}

// Sweep deletes the rows matching each rule in batches. A failure in one
// rule is remembered and the others still run, so a single stuck table
// cannot stop the rest from being cleaned.
func Sweep(ctx context.Context, db Querier, rules ...SweepRule) error {
	var errs []error
	for _, r := range rules {
		if err := sweepOne(ctx, db, r); err != nil {
			errs = append(errs, fmt.Errorf("sweep %s: %w", r.Table, err))
		}
	}
	return errors.Join(errs...)
}

func sweepOne(ctx context.Context, db Querier, r SweepRule) error {
	q := fmt.Sprintf(`DELETE FROM %[1]s WHERE ctid IN (SELECT ctid FROM %[1]s WHERE %[2]s LIMIT %[3]d)`,
		r.Table, r.Where, sweepBatch)
	for {
		tag, err := db.Exec(ctx, q, r.Args...)
		if err != nil {
			return err
		}
		if tag.RowsAffected() < sweepBatch {
			return nil
		}
		// Give other work a turn between batches.
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(50 * time.Millisecond):
		}
	}
}

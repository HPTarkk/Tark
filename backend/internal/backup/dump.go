package backup

import (
	"bufio"
	"compress/gzip"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/HPTarkk/Tark/backend/internal/store"
)

// Inside the encryption the stream is gzip-compressed and holds:
//
//	block(header JSON) | per table: block(COPY data)... block(empty) | block(trailer JSON)
//
// where block = length (4 bytes, big endian) | bytes. Table data is
// PostgreSQL's binary COPY format, so every type round-trips exactly.

const format = 1

type header struct {
	Format     int       `json:"format"`
	CreatedAt  time.Time `json:"created_at"`
	Migrations []string  `json:"migrations"`
	Tables     []table   `json:"tables"`
}

type table struct {
	Name    string   `json:"name"`
	Columns []string `json:"columns"`
}

type trailer struct {
	Rows map[string]int64 `json:"rows"`
}

// Summary describes a backup's contents.
type Summary struct {
	CreatedAt  time.Time
	Migrations []string
	Rows       map[string]int64
}

func (s Summary) TotalRows() int64 {
	var n int64
	for _, r := range s.Rows {
		n += r
	}
	return n
}

const maxBlock = 64 << 20

func writeBlock(w io.Writer, b []byte) error {
	var n [4]byte
	binary.BigEndian.PutUint32(n[:], uint32(len(b)))
	if _, err := w.Write(n[:]); err != nil {
		return err
	}
	_, err := w.Write(b)
	return err
}

func readBlock(r io.Reader) ([]byte, error) {
	var n [4]byte
	if _, err := io.ReadFull(r, n[:]); err != nil {
		return nil, ErrCorrupt
	}
	size := binary.BigEndian.Uint32(n[:])
	if size > maxBlock {
		return nil, ErrCorrupt
	}
	b := make([]byte, size)
	if _, err := io.ReadFull(r, b); err != nil {
		return nil, ErrCorrupt
	}
	return b, nil
}

// blockWriter turns the many small writes of a COPY into blocks of about
// 32 KiB. End flushes and writes the empty block that ends the table.
type blockWriter struct {
	w   io.Writer
	buf []byte
}

func (b *blockWriter) Write(p []byte) (int, error) {
	b.buf = append(b.buf, p...)
	if len(b.buf) >= 32<<10 {
		if err := writeBlock(b.w, b.buf); err != nil {
			return 0, err
		}
		b.buf = b.buf[:0]
	}
	return len(p), nil
}

func (b *blockWriter) End() error {
	if len(b.buf) > 0 {
		if err := writeBlock(b.w, b.buf); err != nil {
			return err
		}
		b.buf = b.buf[:0]
	}
	return writeBlock(b.w, nil)
}

// blockReader reads one table's blocks and reports EOF at its empty block.
type blockReader struct {
	r    io.Reader
	cur  []byte
	done bool
	n    int64
}

func (b *blockReader) Read(p []byte) (int, error) {
	for len(b.cur) == 0 {
		if b.done {
			return 0, io.EOF
		}
		blk, err := readBlock(b.r)
		if err != nil {
			return 0, err
		}
		if len(blk) == 0 {
			b.done = true
			return 0, io.EOF
		}
		b.cur = blk
	}
	n := copy(p, b.cur)
	b.cur = b.cur[n:]
	b.n += int64(n)
	return n, nil
}

// drain reads to the table's end, for verification without a database.
func (b *blockReader) drain() error {
	_, err := io.Copy(io.Discard, b)
	return err
}

// Dump writes an encrypted backup of every table in the public schema to w.
// All tables are read in one repeatable-read transaction, so the backup is
// a consistent snapshot even while the service keeps running.
func Dump(ctx context.Context, pool *pgxpool.Pool, w io.Writer, key []byte) (Summary, error) {
	sum := Summary{Rows: map[string]int64{}}
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return sum, err
	}
	defer conn.Release()
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return sum, err
	}
	defer tx.Rollback(context.Background()) //nolint:errcheck
	// The pool's 15 s statement limit is for requests; a large table can take
	// longer to copy.
	if _, err := tx.Exec(ctx, "SET LOCAL statement_timeout = 0"); err != nil {
		return sum, err
	}

	h := header{Format: format, CreatedAt: time.Now().UTC().Truncate(time.Second)}
	rows, err := tx.Query(ctx, "SELECT version FROM schema_migrations ORDER BY version")
	if err != nil {
		return sum, err
	}
	h.Migrations, err = pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return sum, err
	}
	names, err := tableOrder(ctx, tx)
	if err != nil {
		return sum, err
	}
	for _, name := range names {
		if name == "schema_migrations" {
			continue
		}
		cols, err := columns(ctx, tx, name)
		if err != nil {
			return sum, err
		}
		h.Tables = append(h.Tables, table{Name: name, Columns: cols})
	}

	sealer, err := newSealWriter(w, key)
	if err != nil {
		return sum, err
	}
	zw, err := gzip.NewWriterLevel(sealer, gzip.BestSpeed)
	if err != nil {
		return sum, err
	}
	bw := bufio.NewWriterSize(zw, 64<<10)
	hj, _ := json.Marshal(h)
	if err := writeBlock(bw, hj); err != nil {
		return sum, err
	}
	for _, t := range h.Tables {
		blocks := &blockWriter{w: bw}
		tag, err := tx.Conn().PgConn().CopyTo(ctx, blocks,
			fmt.Sprintf("COPY %s (%s) TO STDOUT (FORMAT binary)", ident(t.Name), identList(t.Columns)))
		if err != nil {
			return sum, fmt.Errorf("backup: copy %s: %w", t.Name, err)
		}
		if err := blocks.End(); err != nil {
			return sum, err
		}
		sum.Rows[t.Name] = tag.RowsAffected()
	}
	tj, _ := json.Marshal(trailer{Rows: sum.Rows})
	if err := writeBlock(bw, tj); err != nil {
		return sum, err
	}
	if err := bw.Flush(); err != nil {
		return sum, err
	}
	if err := zw.Close(); err != nil {
		return sum, err
	}
	if err := sealer.Close(); err != nil {
		return sum, err
	}
	sum.CreatedAt, sum.Migrations = h.CreatedAt, h.Migrations
	return sum, tx.Commit(ctx)
}

// reader opens the encrypted stream and reads its header.
func reader(r io.Reader, key []byte) (io.Reader, *gzip.Reader, header, error) {
	var h header
	or, err := newOpenReader(r, key)
	if err != nil {
		return nil, nil, h, err
	}
	zr, err := gzip.NewReader(or)
	if err != nil {
		if errors.Is(err, ErrCorrupt) {
			return nil, nil, h, err
		}
		return nil, nil, h, ErrCorrupt
	}
	br := bufio.NewReaderSize(zr, 64<<10)
	hj, err := readBlock(br)
	if err != nil {
		return nil, nil, h, err
	}
	if err := json.Unmarshal(hj, &h); err != nil || h.Format != format {
		return nil, nil, h, fmt.Errorf("backup: unsupported backup format")
	}
	return br, zr, h, nil
}

func finish(br io.Reader, zr *gzip.Reader, h header) (Summary, error) {
	tj, err := readBlock(br)
	if err != nil {
		return Summary{}, err
	}
	var t trailer
	if err := json.Unmarshal(tj, &t); err != nil {
		return Summary{}, ErrCorrupt
	}
	// The gzip stream must end here, and its checksum must match.
	if _, err := br.Read(make([]byte, 1)); err != io.EOF {
		return Summary{}, ErrCorrupt
	}
	if err := zr.Close(); err != nil {
		return Summary{}, ErrCorrupt
	}
	return Summary{CreatedAt: h.CreatedAt, Migrations: h.Migrations, Rows: t.Rows}, nil
}

// Verify decrypts and reads a whole backup without touching a database. A
// nil error means every byte authenticated and the structure is complete.
func Verify(r io.Reader, key []byte) (Summary, error) {
	br, zr, h, err := reader(r, key)
	if err != nil {
		return Summary{}, err
	}
	for range h.Tables {
		if err := (&blockReader{r: br}).drain(); err != nil {
			return Summary{}, err
		}
	}
	return finish(br, zr, h)
}

// Restore loads a backup into an empty database: it builds the schema the
// backup was taken with, loads every table in one transaction, then applies
// any newer migrations this build has. It refuses a database that already
// has tables, so it can never overwrite live data.
func Restore(ctx context.Context, pool *pgxpool.Pool, r io.Reader, key []byte) (Summary, error) {
	var existing int
	if err := pool.QueryRow(ctx,
		`SELECT count(*) FROM pg_tables WHERE schemaname = 'public'`).Scan(&existing); err != nil {
		return Summary{}, err
	}
	if existing > 0 {
		return Summary{}, fmt.Errorf("backup: the target database already has %d tables; restore only into an empty database", existing)
	}
	br, zr, h, err := reader(r, key)
	if err != nil {
		return Summary{}, err
	}
	if err := store.MigrateOnly(ctx, pool, h.Migrations); err != nil {
		return Summary{}, err
	}
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return Summary{}, err
	}
	defer conn.Release()
	tx, err := conn.Begin(ctx)
	if err != nil {
		return Summary{}, err
	}
	defer tx.Rollback(context.Background()) //nolint:errcheck
	if _, err := tx.Exec(ctx, "SET LOCAL statement_timeout = 0"); err != nil {
		return Summary{}, err
	}
	for _, t := range h.Tables {
		blocks := &blockReader{r: br}
		if _, err := tx.Conn().PgConn().CopyFrom(ctx, blocks,
			fmt.Sprintf("COPY %s (%s) FROM STDIN (FORMAT binary)", ident(t.Name), identList(t.Columns))); err != nil {
			return Summary{}, fmt.Errorf("backup: load %s: %w", t.Name, err)
		}
		if err := blocks.drain(); err != nil {
			return Summary{}, err
		}
	}
	sum, err := finish(br, zr, h)
	if err != nil {
		return Summary{}, err
	}
	// Identity columns were loaded with their old values; move each sequence
	// past them so new rows do not collide.
	idRows, err := tx.Query(ctx, `
		SELECT table_name, column_name FROM information_schema.columns
		WHERE table_schema = 'public' AND is_identity = 'YES'`)
	if err != nil {
		return Summary{}, err
	}
	type idCol struct{ table, column string }
	ids, err := pgx.CollectRows(idRows, func(row pgx.CollectableRow) (idCol, error) {
		var c idCol
		return c, row.Scan(&c.table, &c.column)
	})
	if err != nil {
		return Summary{}, err
	}
	for _, c := range ids {
		if _, err := tx.Exec(ctx, fmt.Sprintf(
			`SELECT setval(pg_get_serial_sequence($1, $2), (SELECT COALESCE(max(%s), 0) + 1 FROM %s), false)`,
			ident(c.column), ident(c.table)), c.table, c.column); err != nil {
			return Summary{}, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return Summary{}, err
	}
	return sum, store.Migrate(ctx, pool)
}

// tableOrder lists the public tables so that every table comes after the
// tables its foreign keys point at; loading in this order never violates a
// constraint.
func tableOrder(ctx context.Context, q store.Querier) ([]string, error) {
	rows, err := q.Query(ctx, `SELECT relname FROM pg_class
		WHERE relnamespace = 'public'::regnamespace AND relkind IN ('r', 'p') ORDER BY relname`)
	if err != nil {
		return nil, err
	}
	names, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return nil, err
	}
	rows, err = q.Query(ctx, `
		SELECT ch.relname, pa.relname FROM pg_constraint k
		JOIN pg_class ch ON ch.oid = k.conrelid
		JOIN pg_class pa ON pa.oid = k.confrelid
		WHERE k.contype = 'f' AND k.connamespace = 'public'::regnamespace AND ch.oid <> pa.oid`)
	if err != nil {
		return nil, err
	}
	deps := map[string][]string{}
	for rows.Next() {
		var child, parent string
		if err := rows.Scan(&child, &parent); err != nil {
			rows.Close()
			return nil, err
		}
		deps[child] = append(deps[child], parent)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for _, d := range deps {
		sort.Strings(d)
	}
	var out []string
	state := map[string]int{} // 1 visiting, 2 done
	var visit func(string) error
	visit = func(n string) error {
		switch state[n] {
		case 1:
			return fmt.Errorf("backup: foreign keys form a cycle at %s", n)
		case 2:
			return nil
		}
		state[n] = 1
		for _, p := range deps[n] {
			if err := visit(p); err != nil {
				return err
			}
		}
		state[n] = 2
		out = append(out, n)
		return nil
	}
	for _, n := range names {
		if err := visit(n); err != nil {
			return nil, err
		}
	}
	return out, nil
}

// columns lists the columns a COPY must name: all but generated ones.
func columns(ctx context.Context, q store.Querier, tbl string) ([]string, error) {
	rows, err := q.Query(ctx, `
		SELECT attname FROM pg_attribute
		WHERE attrelid = $1::regclass AND attnum > 0 AND NOT attisdropped AND attgenerated = ''
		ORDER BY attnum`, ident(tbl))
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[string])
}

func ident(s string) string { return pgx.Identifier{s}.Sanitize() }

func identList(cols []string) string {
	out := ""
	for i, c := range cols {
		if i > 0 {
			out += ", "
		}
		out += ident(c)
	}
	return out
}

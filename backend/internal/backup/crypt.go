package backup

import (
	"bufio"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
)

// File layout:
//
//	magic (8 bytes) | salt (32 bytes) | frame...
//	frame = last flag (1 byte) | ciphertext length (4 bytes, big endian) | ciphertext
//
// Each frame is one chunk of at most chunkSize bytes sealed with AES-256-GCM
// under a key derived from the backup key and this file's random salt. The
// nonce is the chunk counter followed by the last flag, so chunks cannot be
// reordered, dropped, or the file cut short without decryption failing.
const (
	magic     = "TARKBK01"
	saltSize  = 32
	chunkSize = 64 << 10
	maxFrame  = chunkSize + 16
	keyInfo   = "tark backup v1"
)

// ErrCorrupt means the file was not written with this key, was changed, or
// is incomplete.
var ErrCorrupt = errors.New("backup: file is corrupt, incomplete, or was made with a different key")

func fileCipher(key, salt []byte) (cipher.AEAD, error) {
	k, err := hkdf.Key(sha256.New, key, salt, keyInfo, 32)
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(k)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

func nonce(counter uint64, last bool) []byte {
	n := make([]byte, 12)
	binary.BigEndian.PutUint64(n[3:11], counter)
	if last {
		n[11] = 1
	}
	return n
}

// sealWriter encrypts everything written to it. Close writes the final frame
// and must be called, or the file is unreadable by design.
type sealWriter struct {
	w       io.Writer
	aead    cipher.AEAD
	buf     []byte
	counter uint64
	closed  bool
}

func newSealWriter(w io.Writer, key []byte) (*sealWriter, error) {
	salt := make([]byte, saltSize)
	if _, err := rand.Read(salt); err != nil {
		return nil, err
	}
	aead, err := fileCipher(key, salt)
	if err != nil {
		return nil, err
	}
	if _, err := io.WriteString(w, magic); err != nil {
		return nil, err
	}
	if _, err := w.Write(salt); err != nil {
		return nil, err
	}
	return &sealWriter{w: w, aead: aead, buf: make([]byte, 0, chunkSize)}, nil
}

func (s *sealWriter) Write(p []byte) (int, error) {
	if s.closed {
		return 0, errors.New("backup: write after close")
	}
	n := len(p)
	for len(p) > 0 {
		// A full chunk is only sealed once more data arrives, so the last
		// frame always carries the last flag.
		if len(s.buf) == chunkSize {
			if err := s.frame(false); err != nil {
				return 0, err
			}
		}
		take := min(chunkSize-len(s.buf), len(p))
		s.buf = append(s.buf, p[:take]...)
		p = p[take:]
	}
	return n, nil
}

func (s *sealWriter) frame(last bool) error {
	ct := s.aead.Seal(nil, nonce(s.counter, last), s.buf, nil)
	s.counter++
	s.buf = s.buf[:0]
	head := make([]byte, 5)
	if last {
		head[0] = 1
	}
	binary.BigEndian.PutUint32(head[1:], uint32(len(ct)))
	if _, err := s.w.Write(head); err != nil {
		return err
	}
	_, err := s.w.Write(ct)
	return err
}

func (s *sealWriter) Close() error {
	if s.closed {
		return nil
	}
	s.closed = true
	return s.frame(true)
}

// openReader decrypts a file written by sealWriter. It returns ErrCorrupt
// for any tampering or truncation, including a file that ends early.
type openReader struct {
	r       *bufio.Reader
	aead    cipher.AEAD
	plain   []byte
	counter uint64
	done    bool
}

func newOpenReader(r io.Reader, key []byte) (*openReader, error) {
	br := bufio.NewReaderSize(r, maxFrame+5)
	head := make([]byte, len(magic)+saltSize)
	if _, err := io.ReadFull(br, head); err != nil {
		return nil, ErrCorrupt
	}
	if string(head[:len(magic)]) != magic {
		return nil, fmt.Errorf("backup: not a Tark backup file")
	}
	aead, err := fileCipher(key, head[len(magic):])
	if err != nil {
		return nil, err
	}
	return &openReader{r: br, aead: aead}, nil
}

func (o *openReader) Read(p []byte) (int, error) {
	for len(o.plain) == 0 {
		if o.done {
			return 0, io.EOF
		}
		if err := o.next(); err != nil {
			return 0, err
		}
	}
	n := copy(p, o.plain)
	o.plain = o.plain[n:]
	return n, nil
}

func (o *openReader) next() error {
	head := make([]byte, 5)
	if _, err := io.ReadFull(o.r, head); err != nil {
		return ErrCorrupt
	}
	last := head[0] == 1
	if head[0] > 1 {
		return ErrCorrupt
	}
	size := binary.BigEndian.Uint32(head[1:])
	if size > maxFrame {
		return ErrCorrupt
	}
	ct := make([]byte, size)
	if _, err := io.ReadFull(o.r, ct); err != nil {
		return ErrCorrupt
	}
	plain, err := o.aead.Open(nil, nonce(o.counter, last), ct, nil)
	if err != nil {
		return ErrCorrupt
	}
	o.counter++
	o.plain = plain
	if last {
		o.done = true
		// Nothing may follow the last frame.
		if _, err := o.r.ReadByte(); err != io.EOF {
			return ErrCorrupt
		}
	}
	return nil
}

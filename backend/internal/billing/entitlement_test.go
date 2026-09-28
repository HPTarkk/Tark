package billing

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
)

// Mirrors EntitlementVerifier in lib/core/entitlement/signed_entitlement.dart,
// so a format drift on either side shows up here.
func TestTokenMatchesAppVerifier(t *testing.T) {
	seed := bytes.Repeat([]byte{9}, 32)
	s, err := NewSigner(map[string][]byte{"k1": seed, "k0": bytes.Repeat([]byte{1}, 32)}, "k1")
	if err != nil {
		t.Fatal(err)
	}
	sku := "tark_premium_1m"
	until := int64(1_800_000_000_000)
	tok, err := s.Sign(Payload{Sub: "u", IK: "install", St: "active", SKU: &sku, Until: &until, AR: true, Iat: 1, Pol: Policy{72, 5, 72}})
	if err != nil {
		t.Fatal(err)
	}
	parts := strings.Split(tok, ".")
	if len(parts) != 4 || parts[0] != "v1" || parts[1] != "k1" {
		t.Fatalf("shape %q", tok)
	}
	pubB64 := s.PublicKeys()["k1"]
	pub, _ := base64.RawURLEncoding.DecodeString(pubB64)
	sig, _ := base64.RawURLEncoding.DecodeString(parts[3])
	if len(sig) != 64 || !ed25519.Verify(pub, []byte(parts[0]+"."+parts[1]+"."+parts[2]), sig) {
		t.Fatal("signature does not verify the way the app checks it")
	}
	body, _ := base64.RawURLEncoding.DecodeString(parts[2])
	var m map[string]any
	if err := json.Unmarshal(body, &m); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"sub", "ik", "st", "sku", "until", "ar", "sus", "iat", "pol"} {
		if _, ok := m[k]; !ok {
			t.Errorf("payload lacks %q", k)
		}
	}
	pol := m["pol"].(map[string]any)
	for _, k := range []string{"graceH", "refreshD", "susOfflineH"} {
		if _, ok := pol[k]; !ok {
			t.Errorf("policy lacks %q", k)
		}
	}
	if len(tok) > 4096 {
		t.Fatal("token longer than the app's limit")
	}
}

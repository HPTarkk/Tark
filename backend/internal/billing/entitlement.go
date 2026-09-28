package billing

import (
	"crypto/ed25519"
	"encoding/json"
	"errors"

	"github.com/HPTarkk/Tark/backend/internal/secure"
)

// Payload is EntitlementPayload in backend/api/openapi.yaml. Field names
// and bounds must stay in step with lib/core/entitlement/signed_entitlement.dart.
type Payload struct {
	Sub   string  `json:"sub"`
	IK    string  `json:"ik"`
	St    string  `json:"st"`
	SKU   *string `json:"sku"`
	Until *int64  `json:"until"`
	AR    bool    `json:"ar"`
	Sus   bool    `json:"sus"`
	Iat   int64   `json:"iat"`
	Pol   Policy  `json:"pol"`
}

type Policy struct {
	GraceH      int `json:"graceH"`
	RefreshD    int `json:"refreshD"`
	SusOfflineH int `json:"susOfflineH"`
}

// Signer issues `v1.<kid>.<payload>.<signature>` tokens. The signature is
// Ed25519 over the ASCII bytes of `v1.<kid>.<payload>`. Only the active key
// signs; the others are kept so they can be published while installs
// still carry them.
type Signer struct {
	kid  string
	priv ed25519.PrivateKey
	pubs map[string]ed25519.PublicKey
}

func NewSigner(seeds map[string][]byte, active string) (*Signer, error) {
	seed, ok := seeds[active]
	if !ok {
		return nil, errors.New("billing: active entitlement key missing")
	}
	s := &Signer{kid: active, priv: ed25519.NewKeyFromSeed(seed), pubs: map[string]ed25519.PublicKey{}}
	for kid, sd := range seeds {
		s.pubs[kid] = ed25519.NewKeyFromSeed(sd).Public().(ed25519.PublicKey)
	}
	return s, nil
}

func (s *Signer) Sign(p Payload) (string, error) {
	body, err := json.Marshal(p)
	if err != nil {
		return "", err
	}
	signed := "v1." + s.kid + "." + secure.B64(body)
	return signed + "." + secure.B64(ed25519.Sign(s.priv, []byte(signed))), nil
}

// PublicKeys returns kid -> base64url public key, the format of the app's
// TARK_ENTITLEMENT_KEYS build setting.
func (s *Signer) PublicKeys() map[string]string {
	out := make(map[string]string, len(s.pubs))
	for kid, pub := range s.pubs {
		out[kid] = secure.B64(pub)
	}
	return out
}

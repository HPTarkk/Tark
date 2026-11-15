package auth

import "testing"

func TestConfirmationMatches(t *testing.T) {
	for _, ok := range []string{"DELETE", "delete", " Delete ", "حذف", " حذف‌"} {
		if !confirmationMatches(ok) {
			t.Errorf("%q should match", ok)
		}
	}
	for _, bad := range []string{"", "  ", "DELET", "yes", "پاک", "DELETE ME"} {
		if confirmationMatches(bad) {
			t.Errorf("%q should not match", bad)
		}
	}
}

func TestSplitWebDeleteToken(t *testing.T) {
	h, l, err := splitWebDeleteToken(" aaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ")
	if err != nil || h != "aaaaaaaaaaaaaaaaaaaaaaaa" || l != "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" {
		t.Fatalf("%q %q %v", h, l, err)
	}
	for _, bad := range []string{"", "nodot", "short.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "aaaaaaaaaaaaaaaaaaaaaaaa.short"} {
		if _, _, err := splitWebDeleteToken(bad); err == nil {
			t.Errorf("%q accepted", bad)
		}
	}
}

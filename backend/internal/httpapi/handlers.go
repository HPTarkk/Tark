package httpapi

import (
	"net/http"
	"strings"
	"time"

	"github.com/HPTarkk/Tark/backend/internal/apperr"
	"github.com/HPTarkk/Tark/backend/internal/auth"
	"github.com/HPTarkk/Tark/backend/internal/billing"
	"github.com/HPTarkk/Tark/backend/internal/i18n"
	"github.com/HPTarkk/Tark/backend/internal/mail"
	"github.com/HPTarkk/Tark/backend/internal/profile"
)

const platformHeader = "X-Tark-Platform"

// client gathers what the server knows about the caller. Platform and
// install key are optional headers; locale comes from the body when the
// endpoint has one, else from Accept-Language.
func (a *api) client(r *http.Request, bodyLocale string) (auth.Client, error) {
	platform, err := auth.NormalizePlatform(r.Header.Get(platformHeader))
	if err != nil {
		return auth.Client{}, err
	}
	install := r.Header.Get(installKeyHeader)
	if install != "" && !auth.ValidInstallKey(install) {
		return auth.Client{}, apperr.Validation(installKeyHeader, "malformed")
	}
	locale := bodyLocale
	if locale == "" {
		locale = i18n.From(r.Context())
	}
	return auth.Client{IP: clientIP(r.Context()), Platform: platform, InstallKey: install, Locale: mail.Locale(locale)}, nil
}

func ms(t time.Time) int64 { return t.UnixMilli() }

// ---- response shapes ----------------------------------------------------

type codeSpec struct {
	Length   int    `json:"length"`
	Alphabet string `json:"alphabet"`
}

type flowResponse struct {
	FlowID            string   `json:"flowId"`
	ExpiresAt         int64    `json:"expiresAt"`
	ResendAvailableAt int64    `json:"resendAvailableAt"`
	Code              codeSpec `json:"code"`
}

func flowJSON(f auth.FlowStarted) flowResponse {
	return flowResponse{
		FlowID: f.FlowID, ExpiresAt: ms(f.ExpiresAt), ResendAvailableAt: ms(f.ResendAvailableAt),
		Code: codeSpec{Length: auth.CodeLength, Alphabet: auth.CodeAlphabet},
	}
}

type profileResponse struct {
	ID            string   `json:"id"`
	Name          string   `json:"name"`
	AvatarID      *string  `json:"avatarId"`
	Email         string   `json:"email"`
	SignInMethods []string `json:"signInMethods"`
	CreatedAt     int64    `json:"createdAt"`
	UpdatedAt     int64    `json:"updatedAt"`
}

func profileJSON(p profile.Profile) profileResponse {
	methods := p.SignInMethods
	if methods == nil {
		methods = []string{}
	}
	return profileResponse{ID: p.ID, Name: p.Name, AvatarID: p.AvatarID, Email: p.Email, SignInMethods: methods,
		CreatedAt: ms(p.CreatedAt), UpdatedAt: ms(p.UpdatedAt)}
}

type tokensResponse struct {
	AccessToken           string `json:"accessToken"`
	AccessTokenExpiresAt  int64  `json:"accessTokenExpiresAt"`
	RefreshToken          string `json:"refreshToken"`
	RefreshTokenExpiresAt int64  `json:"refreshTokenExpiresAt"`
}

func tokensJSON(t auth.Tokens) tokensResponse {
	return tokensResponse{AccessToken: t.AccessToken, AccessTokenExpiresAt: ms(t.AccessExpiresAt),
		RefreshToken: t.RefreshToken, RefreshTokenExpiresAt: ms(t.RefreshExpiresAt)}
}

type sessionResponse struct {
	tokensResponse
	NewAccount bool            `json:"newAccount"`
	Profile    profileResponse `json:"profile"`
}

// signedIn answers every successful sign-in with the tokens and the
// profile, so the app can show the signed-in state without another call.
func (a *api) signedIn(w http.ResponseWriter, r *http.Request, s auth.SignedIn) {
	p, err := a.Profile.Get(r.Context(), s.UserID)
	if err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	writeJSON(w, http.StatusOK, sessionResponse{tokensResponse: tokensJSON(s.Tokens), NewAccount: s.NewAccount, Profile: profileJSON(p)})
}

// ---- auth handlers ------------------------------------------------------

func (a *api) register(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Email    string `json:"email"`
		Password string `json:"password"`
		Name     string `json:"name"`
		Locale   string `json:"locale"`
	}
	if err := decode(r, &body); err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	c, err := a.client(r, body.Locale)
	if err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	f, err := a.Auth.Register(r.Context(), auth.RegisterInput{Email: body.Email, Password: body.Password, Name: body.Name}, c)
	if err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	writeJSON(w, http.StatusAccepted, flowJSON(f))
}

func (a *api) resend(purpose string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			FlowID string `json:"flowId"`
		}
		if err := decode(r, &body); err != nil {
			writeError(w, r, a.Log, err)
			return
		}
		c, err := a.client(r, "")
		if err != nil {
			writeError(w, r, a.Log, err)
			return
		}
		var p *auth.Principal
		if purpose == auth.PurposeEmailChange {
			pr := principal(r)
			p = &pr
		}
		f, err := a.Auth.Resend(r.Context(), purpose, body.FlowID, p, c)
		if err != nil {
			writeError(w, r, a.Log, err)
			return
		}
		writeJSON(w, http.StatusAccepted, flowJSON(f))
	}
}

type proofBody struct {
	FlowID    string `json:"flowId"`
	Code      string `json:"code"`
	LinkToken string `json:"linkToken"`
}

func (b proofBody) proof() auth.Proof {
	return auth.Proof{Code: strings.TrimSpace(b.Code), LinkToken: strings.TrimSpace(b.LinkToken)}
}

func (a *api) verifyRegistration(w http.ResponseWriter, r *http.Request) {
	var body proofBody
	if err := decode(r, &body); err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	c, err := a.client(r, "")
	if err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	s, err := a.Auth.VerifyRegistration(r.Context(), body.FlowID, body.proof(), c)
	if err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	a.signedIn(w, r, s)
}

func (a *api) login(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Email    string `json:"email"`
		Password string `json:"password"`
	}
	if err := decode(r, &body); err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	c, err := a.client(r, "")
	if err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	s, err := a.Auth.Login(r.Context(), body.Email, body.Password, c)
	if err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	a.signedIn(w, r, s)
}

func (a *api) googleNonce(w http.ResponseWriter, r *http.Request) {
	c, err := a.client(r, "")
	if err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	n, err := a.Auth.NewGoogleNonce(r.Context(), c)
	if err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"nonce": n.Nonce, "expiresAt": ms(n.ExpiresAt)})
}

func (a *api) google(w http.ResponseWriter, r *http.Request) {
	var body struct {
		IDToken string `json:"idToken"`
		Name    string `json:"name"`
		Locale  string `json:"locale"`
	}
	if err := decode(r, &body); err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	if body.IDToken == "" {
		writeError(w, r, a.Log, apperr.Validation("idToken", "required"))
		return
	}
	c, err := a.client(r, body.Locale)
	if err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	out, err := a.Auth.GoogleSignIn(r.Context(), body.IDToken, body.Name, c)
	if err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	switch {
	case out.SignedIn != nil:
		a.signedIn(w, r, *out.SignedIn)
	case out.MaskedEmail != "":
		writeError(w, r, a.Log, apperr.Conflict("link_required", "enter the password of the existing account").
			With("ticket", out.Ticket).With("ticketExpiresAt", ms(out.TicketExpiresAt)).With("email", out.MaskedEmail))
	default:
		e := apperr.Unprocessable("name_required", "ask for a name and call /auth/google/complete").
			With("ticket", out.Ticket).With("ticketExpiresAt", ms(out.TicketExpiresAt))
		if out.SuggestedName != "" {
			e = e.With("suggestedName", out.SuggestedName)
		}
		writeError(w, r, a.Log, e)
	}
}

func (a *api) googleLink(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Ticket   string `json:"ticket"`
		Password string `json:"password"`
		Locale   string `json:"locale"`
	}
	if err := decode(r, &body); err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	c, err := a.client(r, body.Locale)
	if err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	s, err := a.Auth.LinkGoogle(r.Context(), body.Ticket, body.Password, c)
	if err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	a.signedIn(w, r, s)
}

func (a *api) googleComplete(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Ticket string `json:"ticket"`
		Name   string `json:"name"`
	}
	if err := decode(r, &body); err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	c, err := a.client(r, "")
	if err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	s, err := a.Auth.CompleteGoogleSignup(r.Context(), body.Ticket, body.Name, c)
	if err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	a.signedIn(w, r, s)
}

func (a *api) refresh(w http.ResponseWriter, r *http.Request) {
	var body struct {
		RefreshToken string `json:"refreshToken"`
	}
	if err := decode(r, &body); err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	c, err := a.client(r, "")
	if err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	t, err := a.Auth.Refresh(r.Context(), body.RefreshToken, c)
	if err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	writeJSON(w, http.StatusOK, tokensJSON(t))
}

func (a *api) logout(w http.ResponseWriter, r *http.Request) {
	if err := a.Auth.Logout(r.Context(), principal(r), clientIP(r.Context())); err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *api) logoutAll(w http.ResponseWriter, r *http.Request) {
	if err := a.Auth.LogoutAll(r.Context(), principal(r), clientIP(r.Context())); err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *api) forgot(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Email  string `json:"email"`
		Locale string `json:"locale"`
	}
	if err := decode(r, &body); err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	c, err := a.client(r, body.Locale)
	if err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	f, err := a.Auth.ForgotPassword(r.Context(), body.Email, c)
	if err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	writeJSON(w, http.StatusAccepted, flowJSON(f))
}

func (a *api) verifyReset(w http.ResponseWriter, r *http.Request) {
	var body proofBody
	if err := decode(r, &body); err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	c, err := a.client(r, "")
	if err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	t, err := a.Auth.VerifyReset(r.Context(), body.FlowID, body.proof(), c)
	if err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"resetTicket": t.Ticket, "expiresAt": ms(t.ExpiresAt)})
}

func (a *api) reset(w http.ResponseWriter, r *http.Request) {
	var body struct {
		ResetTicket string `json:"resetTicket"`
		NewPassword string `json:"newPassword"`
	}
	if err := decode(r, &body); err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	c, err := a.client(r, "")
	if err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	s, err := a.Auth.ResetPassword(r.Context(), body.ResetTicket, body.NewPassword, c)
	if err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	a.signedIn(w, r, s)
}

func (a *api) changePassword(w http.ResponseWriter, r *http.Request) {
	var body struct {
		CurrentPassword string `json:"currentPassword"`
		NewPassword     string `json:"newPassword"`
	}
	if err := decode(r, &body); err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	c, err := a.client(r, "")
	if err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	if err := a.Auth.ChangePassword(r.Context(), principal(r), body.CurrentPassword, body.NewPassword, c); err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *api) deleteAccount(w http.ResponseWriter, r *http.Request) {
	var body struct {
		ConfirmEmail             string `json:"confirmEmail"`
		CurrentPassword          string `json:"currentPassword"`
		GoogleIDToken            string `json:"googleIdToken"`
		SubscriptionAcknowledged bool   `json:"subscriptionAcknowledged"`
		Locale                   string `json:"locale"`
	}
	if err := decode(r, &body); err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	c, err := a.client(r, body.Locale)
	if err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	if err := a.Auth.DeleteAccount(r.Context(), principal(r), auth.DeleteAccountInput{
		ConfirmEmail: body.ConfirmEmail, CurrentPassword: body.CurrentPassword, GoogleIDToken: body.GoogleIDToken,
		SubscriptionAcknowledged: body.SubscriptionAcknowledged}, c); err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *api) startEmailChange(w http.ResponseWriter, r *http.Request) {
	var body struct {
		NewEmail        string `json:"newEmail"`
		CurrentPassword string `json:"currentPassword"`
		GoogleIDToken   string `json:"googleIdToken"`
		Locale          string `json:"locale"`
	}
	if err := decode(r, &body); err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	c, err := a.client(r, body.Locale)
	if err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	f, err := a.Auth.StartEmailChange(r.Context(), principal(r), auth.EmailChangeInput{
		NewEmail: body.NewEmail, CurrentPassword: body.CurrentPassword, GoogleIDToken: body.GoogleIDToken}, c)
	if err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	writeJSON(w, http.StatusAccepted, flowJSON(f))
}

func (a *api) confirmEmailChange(w http.ResponseWriter, r *http.Request) {
	var body proofBody
	if err := decode(r, &body); err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	c, err := a.client(r, "")
	if err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	if err := a.Auth.ConfirmEmailChange(r.Context(), principal(r), body.FlowID, body.proof(), c); err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	a.getProfile(w, r)
}

// ---- profile ------------------------------------------------------------

func (a *api) getProfile(w http.ResponseWriter, r *http.Request) {
	p, err := a.Profile.Get(r.Context(), principal(r).UserID)
	if err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	w.Header().Set("ETag", p.ETag())
	writeJSON(w, http.StatusOK, profileJSON(p))
}

func (a *api) putProfile(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Name     string  `json:"name"`
		AvatarID *string `json:"avatarId"`
	}
	if err := decode(r, &body); err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	p, err := a.Profile.Put(r.Context(), principal(r).UserID, profile.Update{
		Name: body.Name, AvatarID: body.AvatarID, IfMatch: r.Header.Get("If-Match")})
	if err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	w.Header().Set("ETag", p.ETag())
	writeJSON(w, http.StatusOK, profileJSON(p))
}

// ---- subscription -------------------------------------------------------

type subscriptionResponse struct {
	Entitlement   string `json:"entitlement"`
	BazaarChecked bool   `json:"bazaarChecked"`
	// PlanTitle names the entitlement's plan in the request's language.
	// Display only; the app keeps it next to the entitlement.
	PlanTitle *string `json:"planTitle"`
}

func newSubscriptionResponse(r *http.Request, res billing.Result) subscriptionResponse {
	out := subscriptionResponse{Entitlement: res.Entitlement, BazaarChecked: res.BazaarChecked}
	if title, ok := billing.PlanTitle(res.SKU, i18n.From(r.Context())); ok {
		out.PlanTitle = &title
	}
	return out
}

type planJSON struct {
	SKU     string `json:"sku"`
	Months  int    `json:"months"`
	Days    int    `json:"days"`
	Minutes int    `json:"minutes,omitempty"`
	Title   string `json:"title"`
}

// getPlans lists the plans on sale, in order, with titles in the request's
// language. Prices are not here: the app reads them from Bazaar, which is
// what actually charges.
func (a *api) getPlans(w http.ResponseWriter, r *http.Request) {
	lang := i18n.From(r.Context())
	plans := a.Billing.Plans()
	out := make([]planJSON, 0, len(plans))
	for _, p := range plans {
		out = append(out, planJSON{SKU: p.SKU, Months: p.Months, Days: p.Days(), Minutes: p.Minutes, Title: p.Title(lang)})
	}
	writeJSON(w, http.StatusOK, map[string]any{"plans": out})
}

func (a *api) getSubscription(w http.ResponseWriter, r *http.Request) {
	res, err := a.Billing.Get(r.Context(), principal(r).UserID, r.Header.Get(installKeyHeader), clientIP(r.Context()))
	if err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	writeJSON(w, http.StatusOK, newSubscriptionResponse(r, res))
}

func (a *api) submitPurchase(w http.ResponseWriter, r *http.Request) {
	var body struct {
		SKU           string `json:"sku"`
		PurchaseToken string `json:"purchaseToken"`
	}
	if err := decode(r, &body); err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	res, err := a.Billing.Submit(r.Context(), principal(r).UserID, r.Header.Get(installKeyHeader), body.SKU, body.PurchaseToken, clientIP(r.Context()))
	if err != nil {
		writeError(w, r, a.Log, err)
		return
	}
	writeJSON(w, http.StatusOK, newSubscriptionResponse(r, res))
}

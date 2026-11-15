// The "email me a deletion link" form on /delete-account. Every string comes
// from the page (rendered from legal/delete-account.json), so this file holds
// no copy. The API is on this same origin (/api/…, see the Caddyfile).
//
// The answer is the same whether or not the address has an account, so the
// page never says which one it was.

const root = document.documentElement;
const fa = root.lang === 'fa';
const box = document.querySelector('[data-wdel]');
const reduced = matchMedia('(prefers-reduced-motion: reduce)');
const COOLDOWN = 60;

if (box) {
  const form = box.querySelector('.wdel-form');
  const input = box.querySelector('.wdel-input');
  const msg = box.querySelector('.wdel-msg');
  const send = box.querySelector('.wdel-send');
  const sent = box.querySelector('.wdel-sent');
  const sentBody = box.querySelector('.wdel-sent-body');
  const resend = box.querySelector('.wdel-resend');
  const other = box.querySelector('.wdel-other');
  const d = box.dataset;
  const digits = (v) => (fa ? String(v).replace(/\d/g, (n) => '۰۱۲۳۴۵۶۷۸۹'[n]) : String(v));
  const clock = (s) => digits(`${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`);
  const span = (s) => (s >= 60 ? clock(s) : fa ? `${digits(s)} ثانیه` : `${s}s`);
  let lastEmail = '';
  let cooldown = 0;
  let timer = 0;
  let busy = false;

  box.addEventListener('focusin', () => box.classList.add('is-focused'));
  box.addEventListener('focusout', () => box.classList.remove('is-focused'));
  input.addEventListener('input', () => {
    if (input.getAttribute('aria-invalid') === 'true') { input.removeAttribute('aria-invalid'); msg.textContent = ''; }
  });

  const fail = (text) => {
    msg.textContent = text;
    box.classList.remove('shake');
    void box.offsetWidth;
    if (!reduced.matches) box.classList.add('shake');
  };

  /** Swaps one panel for the other, letting the box's height follow. */
  function swap(fromEl, toEl) {
    const from = box.getBoundingClientRect().height;
    fromEl.hidden = true;
    toEl.hidden = false;
    const to = box.getBoundingClientRect().height;
    if (!reduced.matches && box.animate && Math.abs(to - from) > 2) {
      box.animate([{ height: `${from}px` }, { height: `${to}px` }], { duration: 520, easing: 'cubic-bezier(.22,1,.36,1)' });
    }
  }

  function startCooldown(seconds) {
    cooldown = seconds;
    clearInterval(timer);
    const tick = () => {
      if (cooldown <= 0) {
        clearInterval(timer);
        resend.disabled = false;
        resend.textContent = d.againNow;
        return;
      }
      resend.disabled = true;
      resend.textContent = d.again.replace('{time}', clock(cooldown));
      cooldown--;
    };
    tick();
    timer = setInterval(tick, 1000);
  }

  async function request(email) {
    let res;
    try {
      res = await fetch('/api/v1/account/web-delete/request', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Accept-Language': root.lang },
        body: JSON.stringify({ email, locale: fa ? 'fa' : 'en' }),
        credentials: 'omit',
        cache: 'no-store',
      });
    } catch {
      return { status: 0, body: {} };
    }
    let body = {};
    try { body = await res.json(); } catch {}
    return { status: res.status, body };
  }

  async function submit(email, again) {
    if (busy) return;
    busy = true;
    box.classList.add('is-busy');
    send.disabled = true;
    resend.disabled = true;
    const started = performance.now();
    const res = await request(email);
    // Let the paper plane finish its flight; a reply that lands sooner waits.
    const wait = (reduced.matches ? 0 : 900) - (performance.now() - started);
    if (wait > 0) await new Promise((r) => setTimeout(r, wait));
    busy = false;
    box.classList.remove('is-busy');
    send.disabled = false;

    if (res.status === 202) {
      lastEmail = email;
      sentBody.textContent = '';
      const [before, after] = d.sentBody.split('{email}');
      const b = document.createElement('b');
      b.className = 'wdel-email';
      b.textContent = email;
      sentBody.append(before, b, after ?? '');
      if (!again) swap(form, sent);
      sent.classList.remove('play');
      void sent.offsetWidth;
      sent.classList.add('play');
      sent.focus({ preventScroll: true });
      startCooldown(COOLDOWN);
      return;
    }
    if (again) { swap(sent, form); }
    if (res.status === 400 || res.status === 422) { input.setAttribute('aria-invalid', 'true'); fail(d.errInvalid); input.focus(); return; }
    if (res.status === 429) {
      const secs = Math.max(1, Math.ceil((res.body.retryAfterMs || 60000) / 1000));
      fail(d.errLimited.replace('{time}', span(secs)));
      return;
    }
    fail(res.status === 0 ? d.errNetwork : d.errGeneric);
  }

  form.addEventListener('submit', (event) => {
    event.preventDefault();
    const email = input.value.trim();
    // The server decides what an address is; this only catches the obvious.
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      input.setAttribute('aria-invalid', 'true');
      fail(d.errInvalid);
      input.focus();
      return;
    }
    msg.textContent = '';
    submit(email, false);
  });

  resend.addEventListener('click', () => { if (lastEmail) submit(lastEmail, true); });
  other.addEventListener('click', () => {
    clearInterval(timer);
    swap(sent, form);
    input.select();
    input.focus();
  });
}

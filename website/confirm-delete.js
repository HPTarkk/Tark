// The page an account-deletion email link opens: /confirm-delete#<token>
// (and /fa/confirm-delete). It reads the token from the fragment — which a
// browser never sends to any server — keeps it for this tab only, takes it
// out of the address bar, and talks to the API on this same origin.
//
// Nothing here loads from another site, and the page's CSP forbids it.

const root = document.documentElement;
const lang = root.lang === 'fa' ? 'fa' : 'en';
const fa = lang === 'fa';
const reduced = matchMedia('(prefers-reduced-motion: reduce)');
const API = '/api/v1/account/web-delete/';
const KEY = 'tark_delete_token';
const HOLD_MS = 1300;

const T = {
  en: {
    checking: 'Opening your link…',
    checkingSub: 'Making sure it’s really from your inbox.',
    eyebrow: 'Delete account',
    title: 'Delete this Tarkk account?',
    lede: 'This can’t be undone. Here is exactly what happens.',
    since: d => `Member since ${d}`,
    goes: 'DELETED FOR GOOD',
    goesItems: [
      ['mail', 'Your email address and sign-in (password or Google)'],
      ['user', 'Your name and avatar'],
      ['phone', 'Every signed-in phone is signed out'],
      ['receipt', 'Your purchase and subscription records'],
    ],
    stays: 'WHAT STAYS',
    staysItems: [
      ['radio', 'Tarkk keeps working on your phone without an account'],
      ['shield', 'Security records for up to a year, without your account id'],
    ],
    subTitle: 'Your Bazaar subscription is still running',
    subRenewing: 'Deleting the account doesn’t cancel it: Bazaar keeps renewing it until you cancel it in Bazaar. You can restore the purchase into a new account later.',
    subNotRenewing: 'Deleting the account doesn’t refund it. You can restore the purchase into a new account later.',
    subUntil: d => `Paid until ${d}.`,
    subAck: 'I understand',
    word: 'DELETE',
    confirmLabel: w => ['To confirm, type ', w],
    placeholder: 'Type it here',
    hold: 'Hold to delete my account',
    holdTap: 'Tap again to delete',
    holdHint: 'Press and hold until the bar fills.',
    keep: 'Keep my account',
    expires: t => `Link works for ${t}`,
    deleting: 'Deleting your account…',
    doneTitle: 'Your account is deleted.',
    doneLede: 'Everything listed was removed and every phone was signed out. A confirmation is on its way to your email.',
    doneSub: '<b>One more step:</b> your Bazaar subscription is still running. Cancel it in Bazaar, or it will keep renewing.',
    home: 'Back to Tarkk',
    expiredTitle: 'This link has expired.',
    expiredLede: 'For your safety, deletion links work for 15 minutes. Ask for a new one — it only takes a moment.',
    usedTitle: 'This link was already used.',
    usedLede: 'It has done its job, or a newer link replaced it, or the account’s email has changed since. If the account still exists, ask for a new link.',
    invalidTitle: 'This link doesn’t look right.',
    invalidLede: 'It may have been cut short by your email app. Open it again from the email, or ask for a new one.',
    lockedTitle: 'This link is locked.',
    lockedLede: 'There were too many attempts with it. Ask for a new link.',
    missingTitle: 'Open the link from your email.',
    missingLede: 'This page needs the link we emailed you. To get one, enter your account’s email on the delete-account page.',
    newLink: 'Ask for a new link',
    limitedTitle: 'Too many tries for now.',
    limitedLede: s => `Please wait ${s} and try again.`,
    netTitle: 'We couldn’t reach Tarkk.',
    netLede: 'Check your connection and try again. Nothing was deleted.',
    retry: 'Try again',
    oopsTitle: 'Something went wrong on our side.',
    oopsLede: 'Nothing was deleted. Please try again in a minute.',
    wrongWord: w => `Type ${w} exactly to confirm.`,
    ackFirst: 'Tick “I understand” first.',
    newLinkHref: '/delete-account#by-email',
    homeHref: '/',
  },
  fa: {
    checking: 'داریم لینکت رو باز می‌کنیم…',
    checkingSub: 'مطمئن می‌شیم واقعاً از ایمیل خودت اومده.',
    eyebrow: 'حذف حساب',
    title: 'این حساب تَرک حذف بشه؟',
    lede: 'این کار برگشت‌پذیر نیست. دقیقاً این اتفاق‌ها می‌افته:',
    since: d => `عضو از ${d}`,
    goes: 'برای همیشه پاک می‌شه',
    goesItems: [
      ['mail', 'نشانی ایمیل و روش ورودت (رمز عبور یا گوگل)'],
      ['user', 'اسم و آواتارت'],
      ['phone', 'همه‌ی گوشی‌هایی که وارد حساب بودن ازش خارج می‌شن'],
      ['receipt', 'سابقه‌ی خریدها و اشتراک‌هات'],
    ],
    stays: 'چیزی که می‌مونه',
    staysItems: [
      ['radio', 'تَرک روی گوشیت بدون حساب هم کار می‌کنه'],
      ['shield', 'سوابق امنیتی تا یک سال، بدون شناسه‌ی حسابت'],
    ],
    subTitle: 'اشتراک بازارت هنوز فعاله',
    subRenewing: 'حذف حساب اون رو لغو نمی‌کنه: بازار تا وقتی خودت توی بازار لغوش نکنی تمدیدش می‌کنه. بعداً می‌تونی خریدت رو توی یه حساب تازه بازیابی کنی.',
    subNotRenewing: 'حذف حساب پولش رو برنمی‌گردونه. بعداً می‌تونی خریدت رو توی یه حساب تازه بازیابی کنی.',
    subUntil: d => `پرداخت‌شده تا ${d}.`,
    subAck: 'متوجه شدم',
    word: 'حذف',
    confirmLabel: w => ['برای تأیید، بنویس ', w],
    placeholder: 'اینجا بنویس',
    hold: 'نگه دار تا حسابم حذف بشه',
    holdTap: 'یه بار دیگه بزن تا حذف بشه',
    holdHint: 'دکمه رو نگه دار تا نوار پر بشه.',
    keep: 'حسابم بمونه',
    expires: t => `اعتبار لینک: ${t}`,
    deleting: 'داریم حسابت رو حذف می‌کنیم…',
    doneTitle: 'حسابت حذف شد.',
    doneLede: 'همه‌ی موارد بالا پاک شدن و همه‌ی گوشی‌ها از حساب خارج شدن. یه ایمیل تأیید هم برات فرستادیم.',
    doneSub: '<b>یه کار دیگه مونده:</b> اشتراک بازارت هنوز فعاله. توی بازار لغوش کن، وگرنه تمدید می‌شه.',
    home: 'برگشت به تَرک',
    expiredTitle: 'اعتبار این لینک تموم شده.',
    expiredLede: 'برای امنیتت، لینک حذف فقط ۱۵ دقیقه کار می‌کنه. یه لینک تازه بگیر، فقط چند لحظه طول می‌کشه.',
    usedTitle: 'این لینک قبلاً استفاده شده.',
    usedLede: 'یا کارش رو کرده، یا لینک تازه‌تری جاش رو گرفته، یا ایمیل حساب از اون موقع عوض شده. اگه حساب هنوز هست، یه لینک تازه بگیر.',
    invalidTitle: 'این لینک درست به نظر نمی‌رسه.',
    invalidLede: 'شاید برنامه‌ی ایمیلت بخشی ازش رو بریده باشه. دوباره از توی ایمیل بازش کن، یا یه لینک تازه بگیر.',
    lockedTitle: 'این لینک قفل شده.',
    lockedLede: 'با این لینک بیش از حد تلاش شده. یه لینک تازه بگیر.',
    missingTitle: 'لینک رو از توی ایمیلت باز کن.',
    missingLede: 'این صفحه به لینکی نیاز داره که برات ایمیل کردیم. برای گرفتنش، ایمیل حسابت رو توی صفحه‌ی حذف حساب وارد کن.',
    newLink: 'گرفتن لینک تازه',
    limitedTitle: 'فعلاً تلاش‌ها زیاد شده.',
    limitedLede: s => `لطفاً ${s} صبر کن و دوباره امتحان کن.`,
    netTitle: 'به تَرک دسترسی پیدا نکردیم.',
    netLede: 'اتصال اینترنتت رو بررسی کن و دوباره امتحان کن. چیزی پاک نشده.',
    retry: 'دوباره امتحان کن',
    oopsTitle: 'یه مشکلی سمت ما پیش اومد.',
    oopsLede: 'چیزی پاک نشده. لطفاً یه دقیقه دیگه دوباره امتحان کن.',
    wrongWord: w => `برای تأیید، دقیقاً «${w}» رو بنویس.`,
    ackFirst: 'اول «متوجه شدم» رو تیک بزن.',
    newLinkHref: '/fa/delete-account#by-email',
    homeHref: '/fa/',
  },
}[lang];

// ── Icons (stroke, 24px grid) ──────────────────────────────────────────
const ICON = {
  mail: '<path d="M3 6.5h18v11H3z"/><path d="m3.5 7 8.5 6.5L20.5 7"/>',
  user: '<circle cx="12" cy="8.5" r="3.8"/><path d="M4.5 20c1.4-3.6 4.2-5.4 7.5-5.4s6.1 1.8 7.5 5.4"/>',
  phone: '<rect x="6.5" y="2.8" width="11" height="18.4" rx="2.6"/><path d="M10.5 18h3"/>',
  receipt: '<path d="M6 3h12v18l-3-2-3 2-3-2-3 2z"/><path d="M9 8h6M9 12h6"/>',
  radio: '<path d="M8.5 8.5a5 5 0 0 0 0 7M15.5 8.5a5 5 0 0 1 0 7M5.6 5.6a9 9 0 0 0 0 12.8M18.4 5.6a9 9 0 0 1 0 12.8"/><circle cx="12" cy="12" r="1.6"/>',
  shield: '<path d="M12 3 4.5 6v5.5c0 4.6 3.1 8 7.5 9.5 4.4-1.5 7.5-4.9 7.5-9.5V6z"/>',
  trash: '<path d="M4 7h16M9.5 7V4.5h5V7M6.5 7l1 13h9l1-13"/><path d="M10 11v5.5M14 11v5.5"/>',
};
const svg = (name, cls = '') =>
  `<svg class="${cls}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ICON[name]}</svg>`;

const esc = v => String(v).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const digits = v => (fa ? String(v).replace(/\d/g, d => '۰۱۲۳۴۵۶۷۸۹'[d]) : String(v));
const dateText = ms => {
  try {
    return new Intl.DateTimeFormat(fa ? 'fa-IR-u-ca-persian' : 'en-GB', { year: 'numeric', month: 'long', day: 'numeric' }).format(new Date(ms));
  } catch {
    return new Date(ms).toISOString().slice(0, 10);
  }
};
const clock = s => digits(`${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`);
const waitText = s => (s >= 60 ? (fa ? `${digits(Math.ceil(s / 60))} دقیقه` : `${Math.ceil(s / 60)} min`) : fa ? `${digits(s)} ثانیه` : `${s} s`);

// ── The token: from the fragment once, then this tab's storage ────────
function takeToken() {
  let token = '';
  const hash = decodeURIComponent(location.hash.slice(1));
  if (hash) {
    token = hash;
    try { sessionStorage.setItem(KEY, token); } catch {}
    // Out of the address bar and the history, so it is not shared by a copy.
    history.replaceState(null, '', location.pathname);
  } else {
    try { token = sessionStorage.getItem(KEY) || ''; } catch {}
  }
  return token;
}
const forgetToken = () => { try { sessionStorage.removeItem(KEY); } catch {} };

async function call(path, body) {
  let res;
  try {
    res = await fetch(API + path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Accept-Language': lang },
      body: JSON.stringify(body),
      credentials: 'omit',
      cache: 'no-store',
      referrerPolicy: 'no-referrer',
    });
  } catch {
    return { status: 0, body: {} };
  }
  let data = {};
  try { data = res.status === 204 ? {} : await res.json(); } catch {}
  return { status: res.status, body: data };
}

// ── Views ───────────────────────────────────────────────────────────────
const card = document.getElementById('card');

/** Replaces the card's view, morphing its height between the two. */
function show(html, state = '') {
  document.body.dataset.state = state;
  // A new view starts at the top of the card, wherever the reader was.
  if (card.getBoundingClientRect().top < 0) card.scrollIntoView({ block: 'start', behavior: reduced.matches ? 'auto' : 'smooth' });
  const from = card.getBoundingClientRect().height;
  card.innerHTML = html;
  if (reduced.matches || !card.animate) return;
  const to = card.getBoundingClientRect().height;
  if (Math.abs(to - from) > 2) {
    card.animate([{ height: from + 'px' }, { height: to + 'px' }], { duration: 520, easing: 'cubic-bezier(.22,1,.36,1)' });
  }
}

function checkingView() {
  show(`<div data-view="checking" class="df-checking" role="status">
    <svg class="df-letter" viewBox="0 0 120 120" aria-hidden="true">
      <rect class="lt-card" x="34" y="34" width="52" height="40" rx="5"/>
      <path class="lt-line" d="M44 46h32M44 55h22"/>
      <rect class="lt-body" x="20" y="44" width="80" height="54" rx="10"/>
      <path class="lt-flap" d="M21 48 60 76l39-28"/>
    </svg>
    <h1 class="df-title small">${esc(T.checking)}</h1>
    <p class="df-lede">${esc(T.checkingSub)}</p>
  </div>`);
}

function emblem(kind, mark) {
  const marks = {
    check: 'M34 53l12 12 24-26',
    clock: 'M52 34v19l12 8',
    broken: 'M44 44l16 16M60 44 44 60',
    mail: 'M33 40h38v26H33zM34 41l18 14 18-14',
    wifi: 'M32 46a28 28 0 0 1 40 0M39 54a17 17 0 0 1 26 0M52 64h0',
  };
  return `<svg class="df-emblem ${kind}" viewBox="0 0 104 104" aria-hidden="true">
    <circle class="disc" cx="52" cy="52" r="44"/>
    <circle class="ring" cx="52" cy="52" r="48"/>
    <path class="mark" d="${marks[mark]}"/>
  </svg>`;
}

function resultView({ kind = 'warn', mark, title, lede, action, note = '' }) {
  show(`<div data-view="result" class="df-result df-stagger">
    ${emblem(kind, mark)}
    <h1 class="df-title">${esc(title)}</h1>
    <p class="df-lede">${esc(lede)}</p>
    ${note}
    ${action || ''}
  </div>`);
  card.querySelector('h1')?.focus?.();
}

const newLinkButton = () => `<a class="df-btn" href="${T.newLinkHref}">${esc(T.newLink)}</a>`;

function problem(res, retry) {
  const code = res.body?.code;
  if (res.status === 0) {
    resultView({ mark: 'wifi', title: T.netTitle, lede: T.netLede, action: `<button class="df-btn" id="retry" type="button">${esc(T.retry)}</button>` });
    card.querySelector('#retry').addEventListener('click', retry);
    return;
  }
  if (res.status === 429) {
    const secs = Math.max(1, Math.ceil((res.body.retryAfterMs || 60000) / 1000));
    resultView({ mark: 'clock', title: T.limitedTitle, lede: T.limitedLede(waitText(secs)), action: `<button class="df-btn ghost" id="retry" type="button">${esc(T.retry)}</button>` });
    card.querySelector('#retry').addEventListener('click', retry);
    return;
  }
  if (code === 'flow_expired') { forgetToken(); return resultView({ mark: 'clock', title: T.expiredTitle, lede: T.expiredLede, action: newLinkButton() }); }
  if (code === 'flow_completed') { forgetToken(); return resultView({ mark: 'broken', title: T.usedTitle, lede: T.usedLede, action: newLinkButton() }); }
  if (code === 'code_locked') { forgetToken(); return resultView({ mark: 'broken', title: T.lockedTitle, lede: T.lockedLede, action: newLinkButton() }); }
  if (res.status === 404 || res.status === 422 || code === 'flow_not_found' || code === 'code_invalid') {
    forgetToken();
    return resultView({ mark: 'broken', title: T.invalidTitle, lede: T.invalidLede, action: newLinkButton() });
  }
  resultView({ mark: 'wifi', title: T.oopsTitle, lede: T.oopsLede, action: `<button class="df-btn" id="retry" type="button">${esc(T.retry)}</button>` });
  card.querySelector('#retry').addEventListener('click', retry);
}

// ── Review and delete ───────────────────────────────────────────────────
let timer = 0;

function reviewView(token, info) {
  const sub = info.subscription || {};
  const initial = (info.name || info.email || '?').trim().charAt(0).toUpperCase();
  const word = T.word;
  const [labelText] = T.confirmLabel(word);
  const list = (items, cls) => `<ul class="df-list ${cls}">${items.map(([icon, text]) => `<li><span class="ic">${svg(icon)}</span><span>${esc(text)}</span></li>`).join('')}</ul>`;
  show(`<div data-view="review" class="df-stagger">
    <div><p class="df-eyebrow">${esc(T.eyebrow)}</p><h1 class="df-title" tabindex="-1">${esc(T.title)}</h1><p class="df-lede">${esc(T.lede)}</p></div>
    <div class="df-account">
      <div class="df-avatar" aria-hidden="true">${esc(initial)}</div>
      <div><b>${esc(info.name || '')}</b><span class="ltr">${esc(info.email)}</span><span>${esc(T.since(dateText(info.createdAt)))}</span></div>
    </div>
    <div class="df-group"><h2>${esc(T.goes)}</h2>${list(T.goesItems, 'goes')}</div>
    <div class="df-group"><h2>${esc(T.stays)}</h2>${list(T.staysItems, 'keeps')}</div>
    ${sub.active ? `<div class="df-sub" id="sub">
      <b>${esc(T.subTitle)}</b>
      <p>${esc(sub.autoRenewing ? T.subRenewing : T.subNotRenewing)}${sub.validUntil ? ' ' + esc(T.subUntil(dateText(sub.validUntil))) : ''}</p>
      <label class="df-check"><input type="checkbox" id="ack"><span class="df-box"><svg viewBox="0 0 16 16"><path d="M3 8.5l3.2 3L13 4.5"/></svg></span>${esc(T.subAck)}</label>
    </div>` : ''}
    <div class="df-confirm">
      <label for="word">${esc(labelText)}<span class="df-word" id="wordChip" aria-hidden="true">${esc(word)}</span><span class="sr-only">${esc(word)}</span></label>
      <input class="df-input" id="word" autocomplete="off" autocapitalize="characters" spellcheck="false" placeholder="${esc(T.placeholder)}" aria-describedby="wordErr">
      <p class="df-err" id="wordErr" role="alert"></p>
      <button class="df-hold" id="hold" type="button" aria-disabled="true" aria-describedby="holdHint">
        <span class="fill"></span><span class="lbl">${svg('trash')}<span id="holdLabel">${esc(T.hold)}</span></span>
      </button>
      <p class="df-hold-hint" id="holdHint">${esc(T.holdHint)}</p>
    </div>
    <div class="df-actions"><a href="${T.homeHref}">${esc(T.keep)}</a><span class="df-timer" id="timer" aria-live="off"></span></div>
  </div>`);

  const input = card.querySelector('#word');
  const chip = card.querySelector('#wordChip');
  const err = card.querySelector('#wordErr');
  const ack = card.querySelector('#ack');
  const hold = card.querySelector('#hold');
  const fill = hold.querySelector('.fill');
  const holdLabel = card.querySelector('#holdLabel');
  const timerEl = card.querySelector('#timer');

  const norm = v => v.replace(/[\s‌-‏]/g, '').replace(/ي|ى/g, 'ی').replace(/ك/g, 'ک').toLowerCase();
  const target = norm(word);
  // Either language's word is accepted, as the server does.
  const accepted = [norm('DELETE'), norm('حذف')];
  const matches = () => accepted.includes(norm(input.value));
  const ready = () => matches() && (!ack || ack.checked);

  function refresh() {
    // Persian letters join, so the word is never split into letters; an
    // underline fills as the typed prefix grows instead.
    const typed = norm(input.value);
    let n = 0;
    while (n < typed.length && n < target.length && typed[n] === target[n]) n++;
    chip.style.setProperty('--prog', String(matches() ? 1 : n / target.length));
    chip.classList.toggle('done', matches());
    input.classList.toggle('match', matches());
    const was = hold.classList.contains('ready');
    hold.classList.toggle('ready', ready());
    hold.setAttribute('aria-disabled', String(!ready()));
    if (!was && ready()) document.body.dataset.state = 'danger';
    if (was && !ready()) { document.body.dataset.state = ''; disarm(); }
    if (ready()) err.textContent = '';
  }
  input.addEventListener('input', refresh);
  ack?.addEventListener('change', refresh);

  // Expiry countdown; at zero the link is dead, so say so.
  const end = info.expiresAt;
  const tick = () => {
    const left = Math.max(0, Math.round((end - Date.now()) / 1000));
    timerEl.textContent = T.expires(clock(left));
    if (left <= 0) { clearInterval(timer); forgetToken(); resultView({ mark: 'clock', title: T.expiredTitle, lede: T.expiredLede, action: newLinkButton() }); }
  };
  clearInterval(timer);
  tick();
  timer = setInterval(tick, 1000);

  // Hold to delete. A click with no press behind it (a screen reader or a
  // switch device) arms the button instead, and a second click confirms.
  let start = 0, raf = 0, pressed = false, armed = false, armTimer = 0;
  const setP = p => fill.style.setProperty('--p', p.toFixed(3));
  function explain() {
    if (!matches()) { err.textContent = T.wrongWord(word); card.querySelector('.df-confirm').animate?.([{ transform: 'translateX(0)' }, { transform: 'translateX(-6px)' }, { transform: 'translateX(5px)' }, { transform: 'translateX(0)' }], { duration: reduced.matches ? 1 : 360 }); input.focus(); }
    else if (ack && !ack.checked) { err.textContent = T.ackFirst; card.querySelector('#sub').scrollIntoView({ block: 'center', behavior: reduced.matches ? 'auto' : 'smooth' }); }
  }
  function disarm() { armed = false; clearTimeout(armTimer); hold.classList.remove('armed'); holdLabel.textContent = T.hold; }
  function frame(now) {
    const p = Math.min(1, (now - start) / HOLD_MS);
    setP(p);
    if (p >= 1) { pressed = false; hold.classList.remove('pressing'); navigator.vibrate?.(30); go(); return; }
    raf = requestAnimationFrame(frame);
  }
  function press(e) {
    if (e.button > 0) return;
    if (!ready()) { explain(); return; }
    e.preventDefault();
    if (e.pointerId !== undefined) hold.setPointerCapture?.(e.pointerId);
    pressed = true; start = performance.now(); hold.classList.add('pressing');
    raf = requestAnimationFrame(frame);
  }
  function release() {
    if (!pressed) return;
    pressed = false; cancelAnimationFrame(raf); hold.classList.remove('pressing');
    // The fill springs back rather than vanishing.
    const from = parseFloat(fill.style.getPropertyValue('--p') || '0');
    if (reduced.matches || !fill.animate) { setP(0); return; }
    fill.animate([{ transform: `scaleX(${from})` }, { transform: 'scaleX(0)' }], { duration: 420, easing: 'cubic-bezier(.22,1,.36,1)' });
    setP(0);
  }
  hold.addEventListener('pointerdown', press);
  hold.addEventListener('pointerup', release);
  hold.addEventListener('pointercancel', release);
  hold.addEventListener('lostpointercapture', release);
  hold.addEventListener('contextmenu', e => e.preventDefault());
  // Keyboard: hold Space or Enter.
  hold.addEventListener('keydown', e => {
    if ((e.key === ' ' || e.key === 'Enter') && !e.repeat) { e.preventDefault(); press({ button: 0, preventDefault() {}, pointerId: undefined }); }
  });
  hold.addEventListener('keyup', e => { if (e.key === ' ' || e.key === 'Enter') { e.preventDefault(); release(); } });
  hold.addEventListener('click', e => {
    if (e.detail !== 0) return; // a real press is handled by the hold
    if (!ready()) { explain(); return; }
    if (armed) { disarm(); go(); return; }
    armed = true; hold.classList.add('armed'); holdLabel.textContent = T.holdTap;
    armTimer = setTimeout(disarm, 5000);
  });

  let sending = false;
  async function go() {
    if (sending) return;
    sending = true;
    clearInterval(timer);
    hold.classList.remove('ready', 'armed'); hold.classList.add('busy'); hold.setAttribute('aria-disabled', 'true');
    holdLabel.textContent = T.deleting;
    input.disabled = true; if (ack) ack.disabled = true;
    // The list is crossed out item by item while the request runs.
    const items = [...card.querySelectorAll('.df-list.goes li')];
    const strike = Promise.all(items.map((li, i) => new Promise(r => setTimeout(() => { li.classList.add('struck'); r(); }, reduced.matches ? 0 : 140 * i + 60))));
    const [res] = await Promise.all([
      call('confirm', { token, confirmation: input.value, subscriptionAcknowledged: !!ack?.checked, locale: lang }),
      strike.then(() => new Promise(r => setTimeout(r, reduced.matches ? 0 : 380))),
    ]);
    sending = false;
    hold.classList.remove('busy');
    if (res.status === 204) { forgetToken(); return doneView(!!sub.active); }
    if (res.body?.code === 'confirmation_mismatch' || res.body?.code === 'subscription_active') {
      // The page and server disagree (an older page); show the form again.
      return start2(token);
    }
    problem(res, () => start2(token));
  }
}

function doneView(subscription) {
  const sparks = '<i></i>'.repeat(10);
  show(`<div data-view="done" class="df-result df-stagger">
    <div class="df-burst">${emblem('ok', 'check')}${sparks}</div>
    <h1 class="df-title" tabindex="-1">${esc(T.doneTitle)}</h1>
    <p class="df-lede">${esc(T.doneLede)}</p>
    ${subscription ? `<p class="df-note">${T.doneSub}</p>` : ''}
    <a class="df-btn" href="${T.homeHref}">${esc(T.home)}</a>
  </div>`);
  // Inline style attributes are blocked by the CSP; the CSSOM is not.
  card.querySelectorAll('.df-burst i').forEach((spark, i) => {
    spark.style.setProperty('--a', `${i * 36}deg`);
    spark.style.setProperty('--d', `${(i % 3) * 0.04}s`);
  });
  card.querySelector('h1').focus({ preventScroll: true });
}

async function start2(token) {
  checkingView();
  const started = performance.now();
  const res = await call('inspect', { token });
  // Long enough to see what is happening, never a flash.
  const min = reduced.matches ? 0 : 900;
  const wait = min - (performance.now() - started);
  if (wait > 0) await new Promise(r => setTimeout(r, wait));
  if (res.status === 200) {
    reviewView(token, res.body);
    card.querySelector('h1')?.focus({ preventScroll: true });
    return;
  }
  problem(res, () => start2(token));
}

const token = takeToken();
if (!token) {
  resultView({ mark: 'mail', title: T.missingTitle, lede: T.missingLede, action: newLinkButton() });
} else {
  start2(token);
}

// Remember the language the person reads in, for the rest of the site.
try { localStorage.setItem('tark_lang', lang); } catch {}

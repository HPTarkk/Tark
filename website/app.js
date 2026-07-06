// ── Tark landing — scroll choreography + language toggle ─────────────

(function () {
  'use strict';

  // ── Nav background on scroll ──────────────────────────────────────
  const nav = document.getElementById('nav');
  const onScrollNav = () => nav.classList.toggle('scrolled', window.scrollY > 24);
  window.addEventListener('scroll', onScrollNav, { passive: true });
  onScrollNav();

  // ── Reveal-on-scroll ──────────────────────────────────────────────
  const revealables = document.querySelectorAll('.reveal, .reveal-up');
  const io = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) {
          entry.target.classList.add('visible');
          io.unobserve(entry.target);
        }
      }
    },
    { threshold: 0.18 }
  );
  revealables.forEach((el) => io.observe(el));

  // ── Seamless ticker ───────────────────────────────────────────────
  // translateX(-50%) only loops cleanly when the track is two identical
  // runs AND one run is at least as wide as the viewport. Otherwise a blank
  // gap sweeps in at the loop point on wide screens. Content width varies
  // with text/screen, so build the runs here: repeat the base items until one
  // run covers the viewport, then duplicate it. Rebuild on resize.
  const tickerTrack = document.querySelector('.ticker-track');
  if (tickerTrack) {
    const tickerBox = tickerTrack.parentElement;
    const baseNodes = [...tickerTrack.children]
      .slice(0, tickerTrack.children.length / 2) // one copy from the source markup
      .map((n) => n.cloneNode(true));
    const PX_PER_SEC = 48; // constant scroll speed regardless of run width

    const buildTicker = () => {
      if (!baseNodes.length) return;
      tickerTrack.replaceChildren();
      const appendBase = () =>
        baseNodes.forEach((n) => tickerTrack.appendChild(n.cloneNode(true)));
      appendBase();
      // Grow one run until it spans the viewport (guard against runaway).
      let guard = 0;
      while (tickerTrack.scrollWidth < tickerBox.clientWidth && guard++ < 40) {
        appendBase();
      }
      const runWidth = tickerTrack.scrollWidth;
      // Duplicate the run so -50% lands on an identical copy: no jump, no gap.
      [...tickerTrack.children].forEach((n) =>
        tickerTrack.appendChild(n.cloneNode(true))
      );
      tickerTrack.style.animationDuration =
        Math.max(12, runWidth / PX_PER_SEC) + 's';
    };

    buildTicker();
    let tickerTimer;
    window.addEventListener('resize', () => {
      clearTimeout(tickerTimer);
      tickerTimer = setTimeout(buildTicker, 200);
    });
  }

  // ── Pinned handshake scene ────────────────────────────────────────
  // The 320vh section pins its content; scroll progress through it maps
  // to steps 1..4 (show QR → scan → reply → connected).
  const handshake = document.getElementById('handshake');

  const onScrollScene = () => {
    const rect = handshake.getBoundingClientRect();
    const total = handshake.offsetHeight - window.innerHeight;
    if (total <= 0) return;
    const progress = Math.min(1, Math.max(0, -rect.top / total));
    const step = progress < 0.02 ? 0 : Math.min(4, Math.floor(progress * 4) + 1);
    if (String(step) !== handshake.dataset.step) {
      if (step === 0) {
        delete handshake.dataset.step;
      } else {
        handshake.dataset.step = String(step);
      }
    }
  };
  window.addEventListener('scroll', onScrollScene, { passive: true });
  onScrollScene();

  // ── Language toggle (EN ⇄ FA, with RTL) ───────────────────────────
  const langBtn = document.getElementById('langToggle');
  const translatable = document.querySelectorAll('[data-en]');

  function applyLang(lang) {
    document.documentElement.lang = lang;
    document.documentElement.dir = lang === 'fa' ? 'rtl' : 'ltr';
    translatable.forEach((el) => {
      const text = el.dataset[lang];
      if (text) el.textContent = text;
    });
    langBtn.textContent = lang === 'fa' ? 'English' : 'فارسی';
    try {
      localStorage.setItem('tark_lang', lang);
    } catch (_) {}
  }

  langBtn.addEventListener('click', () => {
    applyLang(document.documentElement.lang === 'fa' ? 'en' : 'fa');
  });

  let saved = null;
  try {
    saved = localStorage.getItem('tark_lang');
  } catch (_) {}
  // Default to Persian on first visit; honour an explicit saved choice after.
  applyLang(saved === 'en' ? 'en' : 'fa');
})();

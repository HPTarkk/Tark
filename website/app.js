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
  if (saved === 'fa' || (saved === null && /^fa\b/.test(navigator.language || ''))) {
    applyLang('fa');
  }
})();

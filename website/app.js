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

  // ── Sound-wave dividers ───────────────────────────────────────────
  // Voice-note-style bars with a traveling amber "playhead". Heights come
  // from two overlapped sines (a speech-like envelope) tapered toward the
  // edges, so the "recording" fades in and out. Negative delays start
  // every bar mid-cycle: the sweep is already in motion on first paint and
  // crosses in 75% of the period, then rests. Each duration/delay pair is
  // "<sweep>, <wiggle>" matching the two animations in styles.css — the
  // wiggle gets a random period and phase per bar so the idle motion never
  // looks mechanical.
  document.querySelectorAll('.signal-divider').forEach((div, di) => {
    const N = 96;
    const sweep = di ? 7.5 : 6; // seconds; differ so the two never sync
    for (let i = 0; i < N; i++) {
      const bar = document.createElement('span');
      const taper = Math.pow(Math.sin((i / (N - 1)) * Math.PI), 0.55);
      const env =
        Math.abs(Math.sin(i * 0.32 + di)) *
        (0.55 + 0.45 * Math.sin(i * 0.11 + di * 2)) * taper;
      bar.style.setProperty('--h', (10 + 80 * env).toFixed(1));
      bar.style.animationDuration =
        sweep + 's, ' + (1.6 + Math.random()).toFixed(2) + 's';
      bar.style.animationDelay =
        ((i / N - 1) * 0.75 * sweep).toFixed(2) + 's, ' +
        (-Math.random() * 3).toFixed(2) + 's';
      div.appendChild(bar);
    }
  });

  // ── Hero cursor spotlight ─────────────────────────────────────────
  const hero = document.querySelector('.hero');
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (hero && !reducedMotion) {
    hero.addEventListener('pointermove', (e) => {
      const rect = hero.getBoundingClientRect();
      hero.style.setProperty('--mx', ((e.clientX - rect.left) / rect.width) * 100 + '%');
      hero.style.setProperty('--my', ((e.clientY - rect.top) / rect.height) * 100 + '%');
    });
  }

  // ── Scroll parallax: hero rings/spotlight + tech-grid background ──
  const techSection = document.querySelector('.tech');
  if (!reducedMotion && (hero || techSection)) {
    const onScrollParallax = () => {
      if (hero) {
        hero.style.setProperty('--parallax', window.scrollY * 0.12 + 'px');
      }
      if (techSection) {
        techSection.style.setProperty('--tech-parallax', window.scrollY * -0.06 + 'px');
      }
    };
    window.addEventListener('scroll', onScrollParallax, { passive: true });
    onScrollParallax();
  }

  // ── Hero signal mesh: peer dots + links + packet hops ─────────────
  // Drifting dots are peers on the LAN; lines connect any pair in range;
  // every so often a bright "packet" hops along one of those links.
  // Runs only while the hero is on screen and the tab is visible.
  // Reduced motion: draws a single static frame instead.
  const meshCanvas = document.getElementById('heroMesh');
  if (meshCanvas && hero) {
    const ctx = meshCanvas.getContext('2d');
    const AMBER = '245, 133, 63';
    const LINK = 150; // max px between dots that still draws a line
    const CURSOR_LINK = 170; // the cursor's reach — a touch further than dots
    const REPEL = 100; // dots gently part around the cursor inside this radius
    const HOP_SECS = 0.7;
    let W = 0, H = 0;
    let dots = [];
    let packets = [];
    let rafId = 0;
    let lastT = 0;
    let spawnT = 0;
    let heroOnScreen = true;
    // The cursor joins the mesh as one more peer (endpoint −1 in packets).
    const mouse = { x: 0, y: 0, active: false };

    const rand = (a, b) => a + Math.random() * (b - a);

    const rebuild = () => {
      const dpr = Math.min(2, window.devicePixelRatio || 1);
      W = hero.clientWidth;
      H = hero.clientHeight;
      meshCanvas.width = W * dpr;
      meshCanvas.height = H * dpr;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      const count = Math.min(70, Math.round((W * H) / 24000));
      dots = Array.from({ length: count }, () => ({
        x: rand(0, W),
        y: rand(0, H),
        vx: rand(-14, 14), // px/sec — a slow drift
        vy: rand(-14, 14),
        r: rand(1, 2.3),
      }));
      packets = [];
    };

    const draw = (dt) => {
      ctx.clearRect(0, 0, W, H);

      for (const d of dots) {
        d.x += d.vx * dt;
        d.y += d.vy * dt;
        // Drift parts gently around the cursor — pushed, never teleported:
        // the clamp keeps a shove from crossing the wrap threshold below.
        if (mouse.active) {
          const dx = d.x - mouse.x, dy = d.y - mouse.y;
          const d2 = dx * dx + dy * dy;
          if (d2 < REPEL * REPEL && d2 > 0.01) {
            const dist = Math.sqrt(d2);
            const f = (1 - dist / REPEL) * 70 * dt;
            d.x = Math.max(-12, Math.min(W + 12, d.x + (dx / dist) * f));
            d.y = Math.max(-12, Math.min(H + 12, d.y + (dy / dist) * f));
          }
        }
        if (d.x < -12) d.x = W + 12; else if (d.x > W + 12) d.x = -12;
        if (d.y < -12) d.y = H + 12; else if (d.y > H + 12) d.y = -12;
      }

      const linked = [];
      for (let i = 0; i < dots.length; i++) {
        for (let j = i + 1; j < dots.length; j++) {
          const a = dots[i], b = dots[j];
          const dx = a.x - b.x, dy = a.y - b.y;
          const d2 = dx * dx + dy * dy;
          if (d2 > LINK * LINK) continue;
          linked.push([i, j]);
          ctx.strokeStyle =
            'rgba(' + AMBER + ',' + ((1 - Math.sqrt(d2) / LINK) * 0.16).toFixed(3) + ')';
          ctx.beginPath();
          ctx.moveTo(a.x, a.y);
          ctx.lineTo(b.x, b.y);
          ctx.stroke();
        }
      }

      // The cursor is a peer too: link it to whatever is in reach.
      const nearCursor = [];
      if (mouse.active) {
        for (let i = 0; i < dots.length; i++) {
          const d = dots[i];
          const dx = d.x - mouse.x, dy = d.y - mouse.y;
          const d2 = dx * dx + dy * dy;
          if (d2 > CURSOR_LINK * CURSOR_LINK) continue;
          nearCursor.push(i);
          ctx.strokeStyle =
            'rgba(' + AMBER + ',' + ((1 - Math.sqrt(d2) / CURSOR_LINK) * 0.3).toFixed(3) + ')';
          ctx.beginPath();
          ctx.moveTo(mouse.x, mouse.y);
          ctx.lineTo(d.x, d.y);
          ctx.stroke();
        }
      }

      ctx.fillStyle = 'rgba(' + AMBER + ', .5)';
      for (const d of dots) {
        ctx.beginPath();
        ctx.arc(d.x, d.y, d.r, 0, Math.PI * 2);
        ctx.fill();
      }

      // "You" — a slightly brighter node under the cursor.
      if (mouse.active) {
        ctx.fillStyle = 'rgba(' + AMBER + ', .9)';
        ctx.beginPath();
        ctx.arc(mouse.x, mouse.y, 2.6, 0, Math.PI * 2);
        ctx.fill();
      }

      // Spawn a packet every so often (max 3 in flight) — on a random live
      // link, or to/from the cursor when it has links of its own.
      spawnT += dt;
      if (spawnT > 0.55 && packets.length < 3) {
        if (mouse.active && nearCursor.length && Math.random() < 0.45) {
          spawnT = 0;
          const i = nearCursor[(Math.random() * nearCursor.length) | 0];
          packets.push(Math.random() < 0.5 ? { a: -1, b: i, t: 0 } : { a: i, b: -1, t: 0 });
        } else if (linked.length) {
          spawnT = 0;
          const [a, b] = linked[(Math.random() * linked.length) | 0];
          packets.push({ a, b, t: 0 });
        }
      }

      for (let k = packets.length - 1; k >= 0; k--) {
        const p = packets[k];
        // A packet tied to the cursor dies if the cursor has left the hero.
        if ((p.a === -1 || p.b === -1) && !mouse.active) { packets.splice(k, 1); continue; }
        p.t += dt / HOP_SECS;
        if (p.t >= 1) { packets.splice(k, 1); continue; }
        const a = p.a === -1 ? mouse : dots[p.a];
        const b = p.b === -1 ? mouse : dots[p.b];
        // Light the whole link up while the packet is in flight...
        ctx.strokeStyle = 'rgba(' + AMBER + ', .3)';
        ctx.beginPath();
        ctx.moveTo(a.x, a.y);
        ctx.lineTo(b.x, b.y);
        ctx.stroke();
        // ...and draw the packet itself as a glowing dot.
        ctx.fillStyle = 'rgba(' + AMBER + ', .95)';
        ctx.shadowColor = 'rgb(' + AMBER + ')';
        ctx.shadowBlur = 9;
        ctx.beginPath();
        ctx.arc(a.x + (b.x - a.x) * p.t, a.y + (b.y - a.y) * p.t, 2.1, 0, Math.PI * 2);
        ctx.fill();
        ctx.shadowBlur = 0;
      }
    };

    const frame = (t) => {
      rafId = 0;
      const dt = Math.min(0.05, (t - lastT) / 1000 || 0.016);
      lastT = t;
      draw(dt);
      schedule();
    };

    const schedule = () => {
      if (!rafId && heroOnScreen && !document.hidden) rafId = requestAnimationFrame(frame);
    };

    const halt = () => {
      if (rafId) { cancelAnimationFrame(rafId); rafId = 0; }
    };

    const resume = () => { lastT = performance.now(); schedule(); };

    rebuild();

    // Track the hero's own box, not the window — embedded/preview panes can
    // settle into their real size without ever firing a window resize.
    let meshTimer;
    const onHeroResize = () => {
      clearTimeout(meshTimer);
      meshTimer = setTimeout(() => {
        if (hero.clientWidth === W && hero.clientHeight === H) return;
        rebuild();
        if (reducedMotion) draw(0);
      }, 200);
    };

    if (reducedMotion) {
      draw(0); // one static frame — still dots and lines, just no motion
      new ResizeObserver(onHeroResize).observe(hero);
    } else {
      resume();
      hero.addEventListener('pointermove', (e) => {
        const rect = hero.getBoundingClientRect();
        mouse.x = e.clientX - rect.left;
        mouse.y = e.clientY - rect.top;
        mouse.active = true;
      });
      hero.addEventListener('pointerleave', () => { mouse.active = false; });
      new IntersectionObserver((entries) => {
        heroOnScreen = entries[0].isIntersecting;
        heroOnScreen ? resume() : halt();
      }).observe(hero);
      document.addEventListener('visibilitychange', () => {
        document.hidden ? halt() : resume();
      });
      new ResizeObserver(onHeroResize).observe(hero);
    }
  }

  // ── Card tilt + shine (first card only — the rest just lift on hover) ──
  const tiltCard = document.querySelector('.card');
  if (tiltCard && !reducedMotion) {
    tiltCard.addEventListener('pointermove', (e) => {
      const rect = tiltCard.getBoundingClientRect();
      const px = (e.clientX - rect.left) / rect.width;
      const py = (e.clientY - rect.top) / rect.height;
      tiltCard.style.setProperty('--mx', px * 100 + '%');
      tiltCard.style.setProperty('--my', py * 100 + '%');
      tiltCard.style.setProperty('--rx', (0.5 - py) * 8 + 'deg');
      tiltCard.style.setProperty('--ry', (px - 0.5) * 10 + 'deg');
    });
    tiltCard.addEventListener('pointerleave', () => {
      tiltCard.style.setProperty('--rx', '0deg');
      tiltCard.style.setProperty('--ry', '0deg');
    });
  }

  // ── Nav scrollspy ──────────────────────────────────────────────────
  const navLinks = [...document.querySelectorAll('.nav-links a')];
  const spySections = navLinks
    .map((a) => document.querySelector(a.getAttribute('href')))
    .filter(Boolean);
  if (spySections.length) {
    const spy = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (!entry.isIntersecting) continue;
          const id = '#' + entry.target.id;
          navLinks.forEach((a) => a.classList.toggle('active', a.getAttribute('href') === id));
        }
      },
      { rootMargin: '-40% 0px -55% 0px' }
    );
    spySections.forEach((s) => spy.observe(s));
  }

  // ── FAQ accordion ──────────────────────────────────────────────────
  document.querySelectorAll('.faq-item').forEach((item) => {
    const q = item.querySelector('.faq-q');
    q.addEventListener('click', () => {
      const isOpen = item.classList.toggle('open');
      q.setAttribute('aria-expanded', String(isOpen));
    });
  });

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

  function applyLang(lang, instant) {
    const swap = () => {
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
    };

    // The ltr/rtl flip can't be animated directly, so it happens while
    // everything is faded to transparent — reads as a cross-fade instead
    // of a jump-cut. Skipped on the initial page load (instant) and for
    // reduced-motion, where it would just be a pointless delay.
    if (instant || window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
      swap();
      return;
    }
    // i18n-fade arms the opacity transition, i18n-out drops opacity to 0.
    // Both go on <html> so element-level transitions stay untouched outside
    // this window (see the language-switch section of styles.css).
    const root = document.documentElement;
    root.classList.add('i18n-fade', 'i18n-out');
    window.setTimeout(() => {
      swap();
      root.classList.remove('i18n-out');
      window.setTimeout(() => root.classList.remove('i18n-fade'), 220);
    }, 180);
  }

  langBtn.addEventListener('click', () => {
    applyLang(document.documentElement.lang === 'fa' ? 'en' : 'fa');
  });

  let saved = null;
  try {
    saved = localStorage.getItem('tark_lang');
  } catch (_) {}
  // Default to Persian on first visit; honour an explicit saved choice after.
  applyLang(saved === 'en' ? 'en' : 'fa', true);
})();

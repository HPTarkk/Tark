// ── Tark landing — scroll choreography + language toggle ─────────────

(function () {
  'use strict';

  // ── One scroll pass per frame ─────────────────────────────────────
  // This page used to attach three separate scroll listeners (nav
  // state, tech-grid parallax, handshake progress), each reading
  // layout and writing styles on every wheel event. Interleaving
  // reads and writes like that forces the browser to re-run layout
  // several times per event, which is exactly what makes scrolling
  // feel heavy. Everything now runs in ONE rAF callback, at most once
  // per frame, no matter how many scroll events fire.
  const scrollJobs = [];
  let scrollQueued = false;

  const runScrollJobs = () => {
    scrollQueued = false;
    const y = window.scrollY;
    for (const job of scrollJobs) job(y);
  };

  window.addEventListener('scroll', () => {
    if (scrollQueued) return;
    scrollQueued = true;
    requestAnimationFrame(runScrollJobs);
  }, { passive: true });

  // Jobs receive the scroll position, so none of them has to read it
  // (or anything else) back out of the document.
  const addScrollJob = (job) => {
    scrollJobs.push(job);
    job(window.scrollY);
  };

  // ── Nav background on scroll ──────────────────────────────────────
  const nav = document.getElementById('nav');
  addScrollJob((y) => nav.classList.toggle('scrolled', y > 24));

  // ── Eased wheel scrolling ─────────────────────────────────────────
  // A mouse wheel notch on Windows is a discrete step (three lines, so
  // roughly a hundred pixels), and the browser applies it in one go:
  // the page lands somewhere new rather than travelling there. Each
  // notch is now added to a target and the page eases toward it, which
  // is the curve you feel rather than the step. Trackpads, touch,
  // keyboard, and reduced-motion all keep the native behaviour.
  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const finePointer = window.matchMedia('(pointer: fine)');

  const maxScroll = () =>
    Math.max(0, document.documentElement.scrollHeight - window.innerHeight);

  let targetY = window.scrollY;
  let glideY = window.scrollY;
  let gliding = false;

  const glide = () => {
    const diff = targetY - glideY;
    // Exponential ease-out: quick off the mark, settling into the last
    // few pixels. Anything slower than this reads as lag, not polish.
    glideY += diff * 0.14;
    if (Math.abs(diff) < 0.5) {
      glideY = targetY;
      gliding = false;
    } else {
      requestAnimationFrame(glide);
    }
    // 'instant' overrides the CSS `scroll-behavior: smooth` that anchor
    // links rely on, so the browser does not try to ease our easing.
    window.scrollTo({ top: glideY, behavior: 'instant' });
  };

  const onWheel = (e) => {
    // Pinch-zoom, and anything that wants to scroll itself, stay native.
    if (e.ctrlKey || e.defaultPrevented) return;
    if (e.target.closest && e.target.closest('[data-native-scroll]')) return;

    e.preventDefault();
    const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? window.innerHeight : 1;
    if (!gliding) glideY = window.scrollY;
    targetY = Math.min(maxScroll(), Math.max(0, targetY + e.deltaY * unit));
    if (!gliding) {
      gliding = true;
      requestAnimationFrame(glide);
    }
  };

  const smoothWheel = !reduceMotion.matches && finePointer.matches;
  if (smoothWheel) window.addEventListener('wheel', onWheel, { passive: false });

  // Anything that is not the wheel (keyboard, scrollbar drag, an anchor
  // link) moves the page on its own; keep the glide's idea of where it
  // is in step with it.
  addScrollJob((y) => {
    if (!gliding) {
      targetY = y;
      glideY = y;
    }
  });

  // ── Custom scrollbar ──────────────────────────────────────────────
  const scrollbar = document.createElement('div');
  scrollbar.className = 'scrollbar idle';
  const thumb = document.createElement('div');
  thumb.className = 'scrollbar-thumb';
  scrollbar.appendChild(thumb);
  document.body.appendChild(scrollbar);
  document.documentElement.classList.add('has-custom-scrollbar');

  let trackHeight = 0;
  let thumbHeight = 0;
  let scrollRange = 0;

  const measureBar = () => {
    trackHeight = scrollbar.clientHeight;
    scrollRange = maxScroll();
    const visible = window.innerHeight / document.documentElement.scrollHeight;
    thumbHeight = Math.max(40, Math.round(trackHeight * visible));
    thumb.style.height = thumbHeight + 'px';
    scrollbar.style.display = scrollRange > 0 ? '' : 'none';
  };

  measureBar();
  new ResizeObserver(measureBar).observe(document.body);
  window.addEventListener('resize', measureBar, { passive: true });

  const thumbTravel = () => Math.max(1, trackHeight - thumbHeight);

  addScrollJob((y) => {
    if (scrollRange <= 0) return;
    const progress = Math.min(1, Math.max(0, y / scrollRange));
    thumb.style.transform =
      'translate3d(0, ' + (thumbTravel() * progress).toFixed(1) + 'px, 0)';
  });

  // Fades out once the page has been still for a moment, so it is a
  // read-out while you scroll rather than a permanent stripe.
  let idleTimer;
  let barAwake = false;
  addScrollJob(() => {
    if (!barAwake) {
      barAwake = true;
      scrollbar.classList.remove('idle');
      scrollbar.classList.add('awake');
    }
    clearTimeout(idleTimer);
    idleTimer = setTimeout(() => {
      barAwake = false;
      scrollbar.classList.remove('awake');
      scrollbar.classList.add('idle');
    }, 1100);
  });

  scrollbar.addEventListener('pointerenter', () => {
    scrollbar.classList.remove('idle');
  });

  // Drag the thumb, or click the track to jump.
  const scrollToProgress = (progress, eased) => {
    const y = Math.min(1, Math.max(0, progress)) * scrollRange;
    targetY = y;
    if (eased && smoothWheel) {
      if (!gliding) {
        gliding = true;
        requestAnimationFrame(glide);
      }
    } else {
      glideY = y;
      window.scrollTo({ top: y, behavior: 'instant' });
    }
  };

  thumb.addEventListener('pointerdown', (e) => {
    e.preventDefault();
    thumb.setPointerCapture(e.pointerId);
    const grabY = e.clientY;
    const grabTop = thumbTravel() * (window.scrollY / (scrollRange || 1));

    const onMove = (ev) => scrollToProgress((grabTop + ev.clientY - grabY) / thumbTravel());
    const onUp = (ev) => {
      thumb.releasePointerCapture(ev.pointerId);
      thumb.removeEventListener('pointermove', onMove);
      thumb.removeEventListener('pointerup', onUp);
      thumb.removeEventListener('pointercancel', onUp);
    };

    thumb.addEventListener('pointermove', onMove);
    thumb.addEventListener('pointerup', onUp);
    thumb.addEventListener('pointercancel', onUp);
  });

  scrollbar.addEventListener('pointerdown', (e) => {
    if (e.target === thumb) return;
    const rect = scrollbar.getBoundingClientRect();
    scrollToProgress((e.clientY - rect.top - thumbHeight / 2) / thumbTravel(), true);
  });

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
      tickerTimer = setTimeout(() => {
        buildTicker();
        // Freshly cloned items carry their English markup — restore the
        // active language so a resize doesn't reset the ticker to English.
        applyLang(document.documentElement.lang === 'fa' ? 'fa' : 'en', true);
      }, 200);
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
      // The sweep runs on the bar's ::after (opacity only), the wiggle on
      // the bar itself (transform only), so each gets its own pair rather
      // than a two-value animation shorthand.
      bar.style.setProperty('--sweep-dur', sweep + 's');
      bar.style.setProperty('--sweep-delay', ((i / N - 1) * 0.75 * sweep).toFixed(2) + 's');
      bar.style.setProperty('--wiggle-dur', (1.6 + Math.random()).toFixed(2) + 's');
      bar.style.setProperty('--wiggle-delay', (-Math.random() * 3).toFixed(2) + 's');
      div.appendChild(bar);
    }
  });

  // ── Hero phone: the audio dial ────────────────────────────────────
  // The app's visualizer drives every bar from its own slice of the
  // waveform, so the ring reads as a level, not as a pattern. A single
  // shared animation with index-based delays gives the opposite: one
  // peak marching around the dial. Each ray therefore gets its own
  // envelope and its own period here, and the two halves are mirrored
  // about the vertical axis exactly as AudioVisualizer folds its bars.
  const rays = document.querySelectorAll('.mock-rays span');
  if (rays.length) {
    const count = rays.length;
    const half = Math.floor(count / 2);
    const envelopes = Array.from({ length: half + 1 }, () => ({
      lo: 0.12 + Math.random() * 0.22, // resting length
      hi: 0.5 + Math.random() * 0.5, // how far this bar swings
      dur: 0.55 + Math.random() * 0.8, // its own period
      delay: -Math.random() * 2, // already mid-bounce on first paint
    }));

    rays.forEach((ray, i) => {
      const env = envelopes[i <= half ? i : count - i];
      ray.style.setProperty('--lo', env.lo.toFixed(2));
      ray.style.setProperty('--hi', env.hi.toFixed(2));
      ray.style.setProperty('--dur', env.dur.toFixed(2) + 's');
      ray.style.setProperty('--delay', env.delay.toFixed(2) + 's');
    });
  }

  // ── Idle the decorative loops that are off screen ─────────────────
  // The waveform dividers alone are 192 permanently-animating bars, and
  // the phone mock adds a couple of dozen more. Those loops used to keep
  // the style engine busy for the entire length of the page; now each
  // block is held still until it is actually near the viewport.
  const loopBlocks = document.querySelectorAll(
    '.signal-divider, .hero-phone, .music-eq, .ticker'
  );
  if (loopBlocks.length) {
    const idleObserver = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          entry.target.classList.toggle('anim-idle', !entry.isIntersecting);
        }
      },
      { rootMargin: '150px 0px' }
    );
    loopBlocks.forEach((el) => {
      el.classList.add('anim-idle');
      idleObserver.observe(el);
    });
  }

  // ── Hero + reduced-motion refs (shared by the mesh + parallax below) ──
  const hero = document.querySelector('.hero');
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  // ── Scroll parallax: tech-grid background ─────────────────────────
  const techGrid = document.querySelector('.tech-grid');
  if (!reducedMotion && techGrid) {
    // The grid used to be repainted on every scroll event for the whole
    // length of the page, including the long stretches where the section
    // is nowhere near the viewport. Now it only moves while it is in
    // (or just outside) view, and only when the value actually changes.
    let techVisible = false;
    let lastOffset = '';

    new IntersectionObserver(
      ([entry]) => { techVisible = entry.isIntersecting; },
      { rootMargin: '300px 0px' }
    ).observe(techGrid);

    addScrollJob((y) => {
      if (!techVisible) return;
      const offset = (y * -0.06).toFixed(1) + 'px';
      if (offset === lastOffset) return;
      lastOffset = offset;
      techGrid.style.backgroundPositionY = offset;
    });
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

  // The scene's geometry only changes when the layout does, so it is
  // measured on resize instead of on every frame. Reading
  // getBoundingClientRect() mid-scroll forces a synchronous layout,
  // and doing that once per wheel event is what used to stutter here.
  let sceneTop = 0;
  let sceneRange = 0;

  const measureScene = () => {
    sceneTop = handshake.getBoundingClientRect().top + window.scrollY;
    sceneRange = handshake.offsetHeight - window.innerHeight;
  };

  measureScene();
  // Height moves with the viewport, the font load, and the RTL swap.
  new ResizeObserver(measureScene).observe(handshake);
  window.addEventListener('resize', measureScene, { passive: true });

  addScrollJob((y) => {
    if (sceneRange <= 0) return;
    const progress = Math.min(1, Math.max(0, (y - sceneTop) / sceneRange));
    const step = progress < 0.02 ? 0 : Math.min(4, Math.floor(progress * 4) + 1);
    if (String(step) === handshake.dataset.step) return;
    if (step === 0) {
      delete handshake.dataset.step;
    } else {
      handshake.dataset.step = String(step);
    }
  });

  // ── Language toggle (EN ⇄ FA, with RTL) ───────────────────────────
  const langBtn = document.getElementById('langToggle');

  function applyLang(lang, instant) {
    const swap = () => {
      document.documentElement.lang = lang;
      document.documentElement.dir = lang === 'fa' ? 'rtl' : 'ltr';
      // Re-query every call: the ticker clones its items on load and on each
      // resize rebuild, so a NodeList captured once would miss the new nodes.
      document.querySelectorAll('[data-en]').forEach((el) => {
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

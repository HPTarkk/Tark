// The first visit has a branded intro; later documents and language changes
// share one horizontal two-panel curtain, including direction and timing.
// Same-page anchors, downloads, external links and modified clicks stay native.
const root = document.documentElement;
const reduced = matchMedia('(prefers-reduced-motion: reduce)');
let leaving = false;
let arrivalDone = false;
const ease = 'cubic-bezier(.65,0,.25,1)';
export async function animateCurtain(curtain, direction, phase, delay = 0) {
  if (!curtain || reduced.matches) return;
  curtain.style.visibility = 'visible';
  const cover = phase === 'cover';
  const from = cover ? direction * 102 : 0;
  const to = cover ? 0 : -direction * 102;
  // Sample GSAP's power3.inOut so legal pages need no GSAP dependency.
  // The language switch uses this same animation rather than a second approximation.
  const frames = Array.from({ length: 51 }, (_, i) => {
    const p = i / 50;
    const progress = p < .5 ? 8 * p ** 4 : 1 - ((-2 * p + 2) ** 4) / 2;
    return { offset: p, transform: `translateX(${from + (to - from) * progress}%)` };
  });
  const jobs = [...curtain.querySelectorAll('.language-panel')].map((panel, i) => panel.animate(
    frames, { duration: cover ? 580 : 720, delay: delay + i * (cover ? 55 : 50), easing: 'linear', fill: 'both' },
  ));
  await Promise.allSettled(jobs.map(animation => animation.finished));
  if (!cover) curtain.style.visibility = 'hidden';
  jobs.forEach(animation => animation.cancel());
}
export function restoreArrivalAnchor() {
  if (arrivalDone) return;
  arrivalDone = true;
  if (!location.hash) return;
  let id; try { id = decodeURIComponent(location.hash.slice(1)); } catch { return; }
  const target = document.getElementById(id);
  if (!target) return;
  const top = id === 'top' || id === 'main' ? 0 : Math.max(0, target.getBoundingClientRect().top + scrollY - 82);
  scrollTo({ top, behavior: 'instant' });
  window.ScrollTrigger?.update();
}
function markReady() {
  root.classList.remove('is-booting');
  root.classList.add('page-loaded');
}
export async function revealCurtain() {
  const loader = document.querySelector('#pageLoader');
  markReady();
  restoreArrivalAnchor();
  if (loader) {
    loader.removeAttribute('role');
    loader.removeAttribute('aria-live');
    loader.setAttribute('aria-hidden', 'true');
    loader.querySelectorAll('.loader-center,.loader-kicker').forEach(node => node.remove());
    loader.querySelectorAll('.loader-panel').forEach(node => { node.className = 'language-panel'; });
    await animateCurtain(loader, Number(root.dataset.curtainDirection) === -1 ? -1 : 1, 'open');
    loader.remove();
  }
  root.classList.add('intro-complete');
}
export async function openDocument() {
  const loader = document.querySelector('#pageLoader');
  const fonts = document.fonts.ready;
  await Promise.race([fonts, new Promise(resolve => setTimeout(resolve, 4000))]);
  if (root.dataset.pageEntry === 'curtain') { await revealCurtain(); return; }
  markReady();
  restoreArrivalAnchor();
  if (!loader || reduced.matches) {
    loader?.remove(); root.classList.add('intro-complete'); return;
  }
  loader.querySelector('#loadProgress')?.style.setProperty('--load-progress', 1);
  const percent = loader.querySelector('#loadPercent');
  if (percent) percent.textContent = root.lang === 'fa' ? '۱۰۰٪' : '100%';
  const panels = [...loader.querySelectorAll('.loader-panel')];
  const jobs = panels.map((panel, i) => panel.animate(
    [{ transform: 'translateY(0)' }, { transform: `translateY(${i ? 102 : -102}%)` }],
    { duration: 1150, delay: 500, easing: ease, fill: 'forwards' },
  ));
  for (const node of loader.querySelectorAll('.loader-center,.loader-kicker')) {
    node.animate([{ opacity: 1, transform: 'translateY(0)' }, { opacity: 0, transform: 'translateY(-25px)' }],
      { duration: 380, delay: 300, easing: 'ease-in', fill: 'forwards' });
  }
  for (const node of document.querySelectorAll('.legal-hero-inner > *, .site-header')) {
    node.animate([{ opacity: 0, transform: 'translateY(20px)' }, { opacity: 1, transform: 'translateY(0)' }],
      { duration: 850, delay: 900, easing: 'cubic-bezier(.22,1,.36,1)' });
  }
  await Promise.allSettled(jobs.map(animation => animation.finished));
  loader.remove(); root.classList.add('intro-complete');
}
async function navigate(link, url) {
  leaving = true;
  root.classList.add('is-page-leaving');
  if (link.id === 'langToggle') {
    try { localStorage.setItem('tark_lang', link.hreflang); } catch {}
  }
  const direction = root.lang === 'fa' ? -1 : 1;
  try { sessionStorage.setItem('tark_page_transition', JSON.stringify({ path: url.pathname, direction, at: Date.now() })); } catch {}
  if (reduced.matches) { location.assign(url.href); return; }
  const loader = document.createElement('div');
  loader.id = 'departureLoader';
  loader.setAttribute('aria-hidden', 'true');
  loader.className = 'language-curtain departure-loader';
  loader.innerHTML = '<div class="language-panel"></div><div class="language-panel"></div>';
  document.body.append(loader);
  await animateCurtain(loader, direction, 'cover');
  location.assign(url.href);
}
document.addEventListener('click', event => {
  if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
  const link = event.target.closest('a[href]');
  if (!link || link.hasAttribute('download') || (link.target && link.target !== '_self')) return;
  const url = new URL(link.href, location.href);
  if (url.origin !== location.origin || !['http:', 'https:'].includes(url.protocol)) return;
  if (url.pathname === location.pathname && url.search === location.search && url.hash) return;
  if (url.pathname.startsWith('/v/')) return;
  event.preventDefault();
  if (!leaving) navigate(link, url);
});
window.addEventListener('pageshow', event => {
  if (!event.persisted) return;
  leaving = false;
  root.classList.remove('is-page-leaving', 'is-booting', 'is-language-changing');
  document.querySelector('#departureLoader')?.remove();
  document.querySelector('#pageLoader')?.remove();
  const curtain = document.querySelector('.language-curtain:not(.departure-loader)');
  curtain?.getAnimations({ subtree: true }).forEach(animation => animation.cancel());
  if (curtain) curtain.style.visibility = 'hidden';
  document.querySelector('#langToggle')?.removeAttribute('aria-busy');
  root.classList.add('page-loaded', 'intro-complete');
});

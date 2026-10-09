// Document navigation shares the landing page's two-panel opening.
// Same-page anchors, downloads, external links and modified clicks stay native.
const root = document.documentElement;
const reduced = matchMedia('(prefers-reduced-motion: reduce)');
const loaderTemplate = document.querySelector('#pageLoader')?.cloneNode(true);
let leaving = false;
let arrivalDone = false;
const ease = 'cubic-bezier(.65,0,.25,1)';
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
export async function openDocument() {
  const loader = document.querySelector('#pageLoader');
  const fonts = document.fonts.ready;
  await Promise.race([fonts, new Promise(resolve => setTimeout(resolve, 4000))]);
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
  if (reduced.matches || !loaderTemplate) { location.assign(url.href); return; }
  const loader = loaderTemplate.cloneNode(true);
  loader.id = 'departureLoader';
  loader.removeAttribute('role'); loader.setAttribute('aria-hidden', 'true');
  // Avoid duplicate IDs while the initial reveal is finishing.
  loader.querySelectorAll('[id]').forEach(node => node.removeAttribute('id'));
  loader.classList.add('departure-loader');
  for (const node of loader.querySelectorAll('.loader-center,.loader-kicker')) node.style.opacity = '0';
  document.body.append(loader);
  const jobs = [...loader.querySelectorAll('.loader-panel')].map((panel, i) => panel.animate(
    [{ transform: `translateY(${i ? 102 : -102}%)` }, { transform: 'translateY(0)' }],
    { duration: 620, easing: ease, fill: 'forwards' },
  ));
  await Promise.allSettled(jobs.map(animation => animation.finished));
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
  document.querySelector('#langToggle')?.removeAttribute('aria-busy');
  root.classList.add('page-loaded', 'intro-complete');
});

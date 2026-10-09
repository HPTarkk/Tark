import { openDocument } from './page-transitions.js?v=site-1';
const root = document.documentElement;
try { localStorage.setItem('tark_lang', root.lang); } catch {}
const menu = document.querySelector('#navLinks');
const toggle = document.querySelector('#menuToggle');
let menuAnimation;
function closeMenu() {
  toggle.setAttribute('aria-expanded', 'false');
  menuAnimation?.cancel();
  if (!menu.classList.contains('open')) return;
  menuAnimation = menu.animate([{ opacity: 1, transform: 'translateY(0)' }, { opacity: 0, transform: 'translateY(-12px)' }], { duration: 220 });
  menuAnimation.finished.then(() => menu.classList.remove('open')).catch(() => {});
}
toggle.addEventListener('click', () => {
  if (menu.classList.contains('open')) { closeMenu(); return; }
  menuAnimation?.cancel();
  menu.classList.add('open'); toggle.setAttribute('aria-expanded', 'true');
  menuAnimation = menu.animate([{ opacity: 0, transform: 'translateY(-12px)' }, { opacity: 1, transform: 'translateY(0)' }], { duration: 320, easing: 'cubic-bezier(.22,1,.36,1)' });
});
document.addEventListener('keydown', event => { if (event.key === 'Escape') closeMenu(); });
menu.addEventListener('click', closeMenu);
const toc = [...document.querySelectorAll('.legal-toc a')];
const sections = [...document.querySelectorAll('.legal-sec')];
let ticking = false;
function updateToc() {
  ticking = false;
  const current = sections.filter(section => section.getBoundingClientRect().top <= 170).at(-1) || sections[0];
  for (const link of toc) {
    const active = link.hash === '#' + current?.id;
    link.classList.toggle('active', active);
    if (active) link.setAttribute('aria-current', 'location'); else link.removeAttribute('aria-current');
  }
}
window.addEventListener('scroll', () => { if (!ticking) { ticking = true; requestAnimationFrame(updateToc); } }, { passive: true });
updateToc();
document.querySelectorAll('a[href^="#"]').forEach(link => link.addEventListener('click', event => {
  if (event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return;
  const target = document.getElementById(link.hash.slice(1));
  if (!target) return;
  event.preventDefault();
  history.replaceState(null, '', link.hash);
  target.scrollIntoView({ behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth', block: 'start' });
  target.setAttribute('tabindex', '-1'); target.focus({ preventScroll: true });
}));
openDocument();

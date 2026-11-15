// Tarkk admin: page-to-page motion. Pages move with the browser's own
// cross-document view transitions (admin.css, "page motion"); this file is
// loaded in <head> without defer so its listener is in place before the
// new page's first paint. Without view transitions it does nothing.
"use strict";

// The menu's order, top to bottom: going down the menu, the new page rises
// from below; going up, it comes down from above. Same page (a form result,
// a filter): no slide, only the cross-fade.
const menuOrder = ["/", "/system", "/users", "/security", "/mail", "/reviews", "/pricing", "/backups", "/admins", "/activity", "/logs", "/settings"];
const place = (path) => {
  let best = -1;
  let len = -1;
  menuOrder.forEach((p, i) => {
    const hit = p === "/" ? path === "/" : path === p || path.startsWith(p + "/");
    if (hit && p.length > len) {
      best = i;
      len = p.length;
    }
  });
  // A page under a menu entry (one user) sits just below it.
  return best + (len > 1 && path.length > len ? 0.5 : 0);
};

// The page being left notes where it was: the new page cannot see it
// (navigation.activation.from stays empty under this panel's headers).
addEventListener("pageswap", (event) => {
  if (!event.viewTransition) return;
  try {
    sessionStorage.setItem("tark-from", location.pathname);
  } catch {}
});

addEventListener("pagereveal", (event) => {
  const shift = event.viewTransition;
  if (!shift) return;
  const root = document.documentElement;
  // Things that animate their own entrance skip it: the transition
  // already carries them in.
  root.classList.add("vt-in");
  let way = "same";
  try {
    const from = sessionStorage.getItem("tark-from");
    sessionStorage.removeItem("tark-from");
    const to = location.pathname;
    if (from === null) {
      way = "fade";
    } else if (from !== to) {
      const a = place(from);
      const b = place(to);
      way = a < 0 || b < 0 || a === b ? "fade" : b > a ? "down" : "up";
    }
  } catch {
    way = "fade";
  }
  // Kept after the transition: taking it off would restart the entrance
  // animations it picks.
  root.dataset.way = way;
  shift.types?.add(way);
});

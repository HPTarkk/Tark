// Tarkk admin, Reviews page. Conveniences on top of a page that works
// without them: every link and form already does its job.
"use strict";

// A view reached by a view transition (a filter, a tab) keeps the page in
// place instead of replaying its entrance. pagereveal fires before the
// first frame, so this script loads in <head>, not deferred.
window.addEventListener("pagereveal", (event) => {
  if (event.viewTransition) document.documentElement.classList.add("vt-nav");
});

// Small storage helpers: a private window or blocked storage just means no
// saved drafts, never a broken page.
const store = {
  get(key) { try { return localStorage.getItem(key); } catch { return null; } },
  set(key, value) { try { localStorage.setItem(key, value); } catch { /* not kept */ } },
  drop(key) { try { localStorage.removeItem(key); } catch { /* nothing to drop */ } },
};
const session = {
  get(key) { try { return sessionStorage.getItem(key); } catch { return null; } },
  set(key, value) { try { sessionStorage.setItem(key, value); } catch { /* not kept */ } },
  drop(key) { try { sessionStorage.removeItem(key); } catch { /* nothing to drop */ } },
};
const draftKey = (id) => `tarkk.reviewDraft.${id}`;
const typing = (el) => el && (el.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName));

document.addEventListener("DOMContentLoaded", () => {
  const params = new URLSearchParams(location.search);

  // ---- filters apply as they change ------------------------------------
  const filters = document.querySelector("form.rv-filters");
  if (filters) {
    filters.classList.add("auto");
    const send = () => {
      // Empty fields stay out of the address, so it reads like the links.
      for (const el of filters.elements) {
        if (el.name && !el.disabled && el.value === "" && el.type !== "checkbox") el.disabled = true;
      }
      const q = filters.elements.namedItem("q");
      if (q && document.activeElement === q) session.set("tarkk.reviewSearchCaret", String(q.selectionStart ?? q.value.length));
      filters.requestSubmit();
    };
    filters.addEventListener("change", (event) => {
      if (event.target.name !== "q") send();
    });
    const q = filters.elements.namedItem("q");
    let timer;
    q?.addEventListener("input", () => {
      clearTimeout(timer);
      timer = setTimeout(send, 650);
    });
    q?.addEventListener("keydown", (event) => {
      if (event.key === "Enter") {
        event.preventDefault();
        clearTimeout(timer);
        send();
      }
    });
    // Searching as you type: the new view keeps the cursor in the box.
    const caret = session.get("tarkk.reviewSearchCaret");
    if (q && caret !== null) {
      session.drop("tarkk.reviewSearchCaret");
      q.focus({ preventScroll: true });
      const at = Math.min(Number(caret) || 0, q.value.length);
      q.setSelectionRange(at, at);
    }
  }

  // ---- composers: drafts, count, keyboard -------------------------------
  const sent = params.get("sent");
  if (sent) store.drop(draftKey(sent));
  for (const area of document.querySelectorAll("textarea[data-draft]")) {
    const id = area.dataset.draft;
    const form = area.form;
    const details = area.closest("details");
    const count = form.querySelector("[data-count]");
    const max = Number(area.maxLength) || 2000;
    const show = () => {
      const n = [...area.value].length;
      if (count) {
        count.textContent = n ? `${n.toLocaleString(document.documentElement.lang)} / ${max.toLocaleString(document.documentElement.lang)}` : "";
        count.classList.toggle("near", n > max * 0.9 && n <= max);
        count.classList.toggle("over", n > max);
      }
    };
    // A draft left on this review comes back, its composer open.
    if (!area.value) {
      const saved = store.get(draftKey(id));
      if (saved) {
        area.value = saved;
        if (details) details.open = true;
      }
    }
    show();
    area.addEventListener("input", () => {
      show();
      if (area.value.trim()) store.set(draftKey(id), area.value);
      else store.drop(draftKey(id));
    });
    area.addEventListener("keydown", (event) => {
      if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) {
        event.preventDefault();
        form.requestSubmit();
      }
      if (event.key === "Escape" && details && !area.value.trim()) {
        details.open = false;
        details.querySelector("summary")?.focus();
      }
    });
    details?.addEventListener("toggle", () => {
      if (details.open) area.focus({ preventScroll: true });
    });
  }
  // A refused reply comes back open; put the cursor at the end of its words.
  const refused = document.querySelector("details.composer[open] textarea[aria-invalid]");
  if (refused) {
    refused.focus({ preventScroll: true });
    refused.setSelectionRange(refused.value.length, refused.value.length);
  }

  // ---- sync button turns while it works ---------------------------------
  for (const form of document.querySelectorAll("form.rv-sync-form")) {
    form.addEventListener("submit", () => form.classList.add("sending"));
  }
  window.addEventListener("pageshow", (event) => {
    if (!event.persisted) return;
    for (const form of document.querySelectorAll("form.sending")) form.classList.remove("sending");
    for (const el of document.querySelectorAll("form.rv-filters [disabled]")) el.disabled = false;
  });

  // ---- keyboard: j / k between reviews, r to reply, / to search ---------
  const cards = () => [...document.querySelectorAll(".rv-cards > .rv")];
  const mark = (card, scroll) => {
    for (const c of document.querySelectorAll(".rv.kb")) c.classList.remove("kb");
    if (!card) return;
    card.classList.add("kb");
    card.focus({ preventScroll: !scroll });
    if (scroll) card.scrollIntoView({ block: "nearest", behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth" });
  };
  document.addEventListener("keydown", (event) => {
    if (event.ctrlKey || event.metaKey || event.altKey || typing(document.activeElement)) return;
    const list = cards();
    const at = list.indexOf(document.activeElement?.closest(".rv"));
    if (event.key === "j" || event.key === "k") {
      if (!list.length) return;
      event.preventDefault();
      const next = at < 0 ? 0 : Math.max(0, Math.min(list.length - 1, at + (event.key === "j" ? 1 : -1)));
      mark(list[next], true);
    } else if (event.key === "r" && at >= 0) {
      const details = list[at].querySelector("details.composer");
      if (!details) return;
      event.preventDefault();
      details.open = true;
      details.querySelector("textarea")?.focus();
    } else if (event.key === "/") {
      const q = filters?.elements.namedItem("q");
      if (!q) return;
      event.preventDefault();
      q.focus();
      q.select();
    }
  });
  document.addEventListener("focusin", (event) => {
    if (!event.target.closest?.(".rv")) for (const c of document.querySelectorAll(".rv.kb")) c.classList.remove("kb");
  });

  // ---- just answered: the next review that needs one is up next ----------
  const done = document.querySelector(".rv.just-sent");
  if (done) {
    const next = done.nextElementSibling?.matches(".rv") ? done.nextElementSibling : null;
    if (next) setTimeout(() => next.classList.add("kb"), 900);
    if (next) next.addEventListener("focusout", () => next.classList.remove("kb"), { once: true });
  }
});

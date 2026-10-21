// Tarkk admin. Small helpers on top of pages that already work without
// scripts: every form still posts the same fields.
"use strict";

// Typed digits may be Persian or Arabic-Indic; forms take Latin ones.
const latin = (s) => s.replace(/[۰-۹]/g, (d) => d.charCodeAt(0) - 0x6f0).replace(/[٠-٩]/g, (d) => d.charCodeAt(0) - 0x660);

// The 6-digit sign-in code is sent as soon as it is complete.
for (const input of document.querySelectorAll("input.otp")) {
  let sent = false;
  input.addEventListener("input", () => {
    const code = latin(input.value).replace(/\D/g, "");
    if (code.length === 6 && !sent) {
      sent = true;
      input.value = code;
      input.form.classList.add("sending");
      input.form.requestSubmit();
    } else if (code.length < 6) {
      sent = false;
    }
  });
}

// Toman amounts get thousands separators while typing; the caret stays
// after the same digit.
for (const input of document.querySelectorAll("input[data-money]")) {
  input.addEventListener("input", () => {
    const before = latin(input.value.slice(0, input.selectionStart)).replace(/\D/g, "").length;
    const digits = latin(input.value).replace(/\D/g, "").replace(/^0+(?=\d)/, "");
    const shown = digits.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
    if (shown === input.value) return;
    input.value = shown;
    let pos = 0;
    for (let seen = 0; pos < shown.length && seen < before; pos++) {
      if (shown[pos] !== ",") seen++;
    }
    input.setSelectionRange(pos, pos);
  });
}

// Copy buttons put the plain number on the clipboard, ready for Bazaar.
for (const button of document.querySelectorAll("button.copy[data-copy]")) {
  if (!navigator.clipboard) continue;
  button.hidden = false;
  const label = button.querySelector("span");
  const idle = label.textContent;
  let timer;
  button.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(button.dataset.copy);
    } catch {
      return;
    }
    button.classList.add("copied");
    label.textContent = button.dataset.done;
    clearTimeout(timer);
    timer = setTimeout(() => {
      button.classList.remove("copied");
      label.textContent = idle;
    }, 1800);
  });
}

// Forms with data-confirm ask first in the shared dialog. The browser has
// already checked the fields when submit fires, so the question only comes
// up for a form that is ready to send.
const confirmBox = document.getElementById("confirm-action");
if (confirmBox) {
  const ok = document.getElementById("confirm-ok");
  let pending = null;
  for (const form of document.querySelectorAll("form[data-confirm]")) {
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      pending = form;
      const danger = form.dataset.confirmTone === "danger";
      document.getElementById("confirm-q").textContent = form.dataset.confirm;
      document.getElementById("confirm-x").textContent = form.dataset.confirmX || "";
      ok.textContent = form.dataset.confirmOk;
      ok.className = danger ? "danger" : "";
      confirmBox.classList.toggle("calm", !danger);
      confirmBox.showPopover();
    });
  }
  ok.addEventListener("click", () => {
    if (!pending) return;
    const form = pending;
    pending = null;
    ok.disabled = true;
    form.submit();
  });
  // Coming back with the browser's Back button shows the page as it was.
  window.addEventListener("pageshow", () => { ok.disabled = false; });
  confirmBox.addEventListener("toggle", (event) => {
    if (event.newState === "closed" && pending) {
      pending.querySelector("button")?.focus();
      pending = null;
    }
  });
}

// A refused add comes back with its drawer open, already in place, and the
// field at fault focused.
for (const drawer of document.querySelectorAll(".drawer[data-open]")) {
  drawer.classList.add("settled");
  drawer.showPopover();
  drawer.querySelector("[aria-invalid]")?.focus();
  requestAnimationFrame(() => requestAnimationFrame(() => drawer.classList.remove("settled")));
}

// Settings: a theme or language is applied the moment it is picked, so the
// Apply button (there for pages without scripts) goes away. A new theme
// spreads out in a circle from the card that was picked, then is saved.
const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
const darkSystem = window.matchMedia("(prefers-color-scheme: dark)");
const looksDark = (theme) => theme === "dark" || (theme !== "light" && darkSystem.matches);
for (const form of document.querySelectorAll("form[data-autosave]")) {
  form.classList.add("auto");
  const send = () => {
    form.classList.add("sending");
    form.submit();
  };
  form.addEventListener("change", (event) => {
    const input = event.target;
    if (form.classList.contains("sending") || !input.checked) return;
    if (form.dataset.autosave !== "theme") {
      send();
      return;
    }
    const root = document.documentElement;
    const before = looksDark(root.dataset.theme);
    const apply = () => {
      if (input.value === "system") delete root.dataset.theme;
      else root.dataset.theme = input.value;
    };
    if (looksDark(input.value) === before || reduceMotion.matches || !document.startViewTransition) {
      apply();
      send();
      return;
    }
    const box = input.closest(".choice").getBoundingClientRect();
    const x = box.left + box.width / 2;
    const y = box.top + box.height / 2;
    const r = Math.hypot(Math.max(x, innerWidth - x), Math.max(y, innerHeight - y));
    root.classList.add("theme-shift");
    const shift = document.startViewTransition(apply);
    shift.ready.then(() => {
      root.animate(
        { clipPath: [`circle(0px at ${x}px ${y}px)`, `circle(${r}px at ${x}px ${y}px)`] },
        { duration: 620, easing: "cubic-bezier(.23, 1, .32, 1)", pseudoElement: "::view-transition-new(root)" },
      );
    }).catch(() => {});
    shift.finished.finally(() => {
      root.classList.remove("theme-shift");
      send();
    });
  });
}
// Back to a page that was left mid-save shows its choices working again.
window.addEventListener("pageshow", (event) => {
  if (!event.persisted) return;
  for (const form of document.querySelectorAll("form[data-autosave]")) form.classList.remove("sending");
});

import { replaceText } from "./motion.js?v=site-1";
const TEXT = {
  fa: {
    brand: "تَرک",
    room: "جاده‌ی شمال",
    nazanin: "نازنین",
    pedram: "پدرام",
    you: "شما",
    host: "میزبان",
    member: "عضو اتاق",
    edit: "ویرایش نام",
    connected: "وصل",
    speaking: "صحبت",
    listening: "دارم گوش می‌دم",
    air: "روی آنتن",
    muted: "ساکتی",
    mic: "میکروفنت",
    live: "میکروفن روشنه",
    liveHint: "همه صدات رو می‌شنون",
    muteHint: "کسی صدات رو نمی‌شنوه",
    muteAction: "ساکت کن",
    unmuteAction: "روشن کن",
    people: "کیا اینجان",
    leave: "خروج از کانال",
    ready: "آماده‌ی حرف زدن",
    auto: "خودکار",
    create: "ساخت اتاق",
    createHint: "یه اتاق بساز و بقیه رو دعوت کن",
    join: "پیوستن با کد دعوت",
    joinHint: "کد روی گوشی میزبان رو اسکن کن",
    settings: "تنظیمات",
    back: "برگشت",
    lobbyTitle: "آماده شروع ارتباط",
    lobbyHint: "تا «شروع ارتباط» رو نزنی، میکروفون خاموش می‌مونه.",
    freshTitle: "اتاق ساخته شد",
    freshHint: "از «دعوت به اتاق» یه نفر رو به جمع خودت اضافه کن.",
    members: "اعضای اتاق (۲)",
    invite: "دعوت به اتاق",
    start: "شروع ارتباط",
    wifiHint: "روی یه وای‌فای هستین؟ از همون وصل شو",
    inviteTitle: "دعوت تازه",
    inviteHint:
      "بذار طرف نزدیک همین گوشی، این کد رو با «پیوستن با کد دعوت» اسکن کنه. مستقیم میاد تو اتاق.",
    copy: "کپی دعوت",
    done: "تمام",
    qr: "نمونه‌ی کد دعوت",
  },
  en: {
    brand: "TARKK",
    room: "Northbound",
    nazanin: "Nazanin",
    pedram: "Pedram",
    you: "You",
    host: "Host",
    member: "Room member",
    edit: "Edit name",
    connected: "Connected",
    speaking: "Talking",
    listening: "LISTENING",
    air: "ON AIR",
    muted: "MUTED",
    mic: "YOUR MIC",
    live: "MIC LIVE",
    liveHint: "The channel can hear you",
    muteHint: "The channel can’t hear you",
    muteAction: "MUTE",
    unmuteAction: "UNMUTE",
    people: "WHO’S HERE",
    leave: "LEAVE CHANNEL",
    ready: "READY TO TALK",
    auto: "AUTO",
    create: "CREATE ROOM",
    createHint: "Start one and invite the others",
    join: "JOIN WITH QR",
    joinHint: "Scan the code on the host’s phone",
    settings: "Settings",
    back: "Back",
    lobbyTitle: "READY TO START",
    lobbyHint: "Your mic stays off until you press Start ride.",
    freshTitle: "ROOM CREATED",
    freshHint: "Open Invite to room to bring someone in.",
    members: "ROOM MEMBERS (2)",
    invite: "INVITE TO ROOM",
    start: "START RIDE",
    wifiHint: "On the same Wi-Fi? Connect over it",
    inviteTitle: "NEW INVITE",
    inviteHint:
      "Have them scan this with Join with QR, close to this phone. They come straight in.",
    copy: "COPY INVITE",
    done: "DONE",
    qr: "Sample invitation code",
  },
};

const ICONS = new Set([
  "microphone",
  "microphone-slash",
  "gear",
  "qr-code",
  "arrow-left",
  "plus",
  "check",
  "bluetooth",
  "wifi",
  "users",
  "headphones",
  "battery-full",
  "cell-signal-full",
  "camera",
  "sign-out",
]);
const icon = (name) =>
  `<span class="icon app-icon" data-icon="${ICONS.has(name) ? name : "check"}" style="--app-icon:url('/assets/icons/${ICONS.has(name) ? name : "check"}.svg')" aria-hidden="true"></span>`;
const avatar = (person, extra = "") =>
  `<img class="app-avatar ${extra}" src="/assets/${person === "nazanin" ? "woman-rider" : "rider"}.webp" alt="" loading="eager" draggable="false">`;

// A deliberately illustrative QR matrix; this UI preview does not issue an invitation.
function sampleQr(label) {
  const n = 29;
  const cells = [];
  const finder = (x, y) => {
    for (let dy = 0; dy < 7; dy++)
      for (let dx = 0; dx < 7; dx++) {
        if (
          dx === 0 ||
          dy === 0 ||
          dx === 6 ||
          dy === 6 ||
          (dx >= 2 && dx <= 4 && dy >= 2 && dy <= 4)
        )
          cells.push(
            `<rect x="${x + dx}" y="${y + dy}" width="1" height="1"/>`,
          );
      }
  };
  finder(0, 0);
  finder(22, 0);
  finder(0, 22);
  for (let y = 0; y < n; y++)
    for (let x = 0; x < n; x++) {
      if (
        (x < 8 && y < 8) ||
        (x > 20 && y < 8) ||
        (x < 8 && y > 20) ||
        (x > 10 && x < 18 && y > 10 && y < 18)
      )
        continue;
      if ((x * 17 + y * 31 + x * y * 3) % 11 < 5)
        cells.push(`<rect x="${x}" y="${y}" width="1" height="1"/>`);
    }
  return `<div class="app-qr"><svg viewBox="-3 -3 35 35" role="img" aria-label="${label}"><g fill="#11151a">${cells.join("")}</g></svg><img src="/assets/logo.png" alt="" class="app-qr-logo"></div>`;
}

/** Source-based HTML reconstruction of Tarkk’s Flutter screens; no microphone or network access. */
export function mountApp(
  root,
  {
    screen = "channel",
    person = "nazanin",
    interactive = false,
    language = "fa",
  } = {},
) {
  if (!root) throw new Error("mountApp requires a screen container");
  const screens = new Set(["channel", "home", "invite", "lobby"]);
  const voices = new Set(["self", "peer", "idle", "muted"]);
  const state = {
    screen: screens.has(screen) ? screen : "channel",
    person: person === "pedram" ? "pedram" : "nazanin",
    voice: "idle",
    hasGuest: screen !== "home",
    language: language === "en" ? "en" : "fa",
    destroyed: false,
    visible: true,
    clock: 0,
  };
  const motion = window.matchMedia("(prefers-reduced-motion: reduce)");
  let frame = 0,
    lastTime = 0,
    canvas = null,
    ctx = null;
  const envelopes = Array(64).fill(0);
  let tintCurrent = [245, 133, 63];
  let previousVoice = "idle";
  root.classList.add("app-view");
  const text = () => TEXT[state.language];
  const peer = () => (state.person === "nazanin" ? "pedram" : "nazanin");
  // The preview only enables local actions it can actually demonstrate.
  const localActions = new Set([
    "mic",
    "create",
    "invite",
    "done",
    "back",
    "start",
    "leave",
  ]);
  const button = (content, action, className = "", label = "") =>
    `<button type="button" class="app-action ${className}" data-app-action="${action}" ${label ? `aria-label="${label}"` : ""} ${interactive && localActions.has(action) ? "" : "disabled"}>${content}</button>`;

  function header(t, back = false) {
    return `<header class="app-header">${back ? button(icon("arrow-left"), "back", "app-square app-back", t.back) : `<div class="app-brand-mark"><img src="/assets/logo.png" alt=""></div>`}<div class="app-brand-copy"><span class="app-room-title">${state.screen === "home" ? t.ready : t.room}</span><b class="app-wordmark">${t.brand}</b></div><div class="app-header-controls"><span class="app-link-glyph">${icon("bluetooth")}</span>${button(icon("gear"), "settings", "app-square app-settings", t.settings)}</div></header>`;
  }
  function identity(t, home = false) {
    return `<section class="app-identity app-card">${avatar(state.person)}<div class="app-person-copy"><div class="app-person-title"><strong>${t[state.person]}</strong><span class="app-identity-controls"><span class="app-edit">${t.edit}</span>${home ? `<span class="app-auto">${t.auto}</span>` : ""}</span></div><span class="app-person-role">${home ? t.ready : state.person === "pedram" ? t.host : t.member}</span></div></section>`;
  }
  function roster(t, lobby = false) {
    const people =
      lobby && !state.hasGuest ? [state.person] : [state.person, peer()];
    const heading = lobby
      ? t.members.replace(
          /[۲2]/,
          state.language === "fa"
            ? state.hasGuest
              ? "۲"
              : "۱"
            : String(people.length),
        )
      : t.people;
    return `<section class="app-roster"><div class="app-section-heading"><span>${heading}</span>${icon("users")}</div><div class="app-roster-card app-card">${people.map((p) => `<div class="app-member" data-app-person="${p}">${avatar(p)}<div class="app-member-copy"><strong><span class="app-member-name">${t[p]}</span>${p === state.person ? `<span class="app-you">${t.you}</span>` : ""}</strong><span>${p === "pedram" ? t.host : t.member}</span></div><span class="app-member-status"><i></i><span>${t.connected}</span></span></div>`).join("")}</div></section>`;
  }
  function channel(t) {
    return `${header(t)}${identity(t)}<section class="app-scope" aria-label="${t.listening}"><div class="app-scope-recess"><canvas class="app-dial" aria-hidden="true"></canvas><div class="app-readout" aria-live="polite"><span class="app-readout-glyph"></span><strong class="app-readout-label"></strong></div></div></section><section class="app-mic-section"><div class="app-section-heading"><span>${t.mic}</span></div>${button(`<span class="app-mic-badge"></span><span class="app-mic-copy"><strong></strong><span></span></span><span class="app-mic-chip"></span>`, "mic", "app-mic-control")}</section>${roster(t)}${button(`${icon("sign-out")}<span>${t.leave}</span>`, "leave", "app-leave")}`;
  }
  function home(t) {
    return `${header(t)}${identity(t, true)}<div class="app-home-options">${button(`<span class="app-entry-icon">${icon("plus")}</span><span class="app-entry-copy"><strong>${t.create}</strong><span>${t.createHint}</span></span>`, "create", "app-entry app-entry-primary")}${button(`<span class="app-entry-icon">${icon("qr-code")}</span><span class="app-entry-copy"><strong>${t.join}</strong><span>${t.joinHint}</span></span>`, "join", "app-entry app-entry-secondary")}</div>`;
  }
  function lobby(t) {
    return `${header(t, true)}<section class="app-lobby-hero app-card"><div class="app-face-stack">${avatar(state.person)}${state.hasGuest ? avatar(peer()) : ""}<span class="app-face-check">${icon("check")}</span></div><h3>${state.hasGuest ? t.lobbyTitle : t.freshTitle}</h3><p>${state.hasGuest ? t.lobbyHint : t.freshHint}</p></section>${roster(t, true)}${button(`${icon("users")}<span>${t.invite}</span>`, "invite", "app-wide app-outline")}${state.hasGuest ? button(`${icon("microphone")}<span>${t.start}</span>`, "start", "app-wide app-primary") : ""}${button(`${icon("wifi")}<span>${t.wifiHint}</span>`, "wifi", "app-wifi-link")}`;
  }
  function invite(t) {
    return `${header(t, true)}<div class="app-sheet-handle"></div><div class="app-invite-heading"><h3>${t.inviteTitle}</h3><p>${t.room}</p></div>${sampleQr(t.qr)}<p class="app-invite-hint">${t.inviteHint}</p><div class="app-invite-actions">${button(t.copy, "copy", "app-wide app-outline")}${button(`${icon("check")}<span>${t.done}</span>`, "done", "app-wide app-primary")}</div>`;
  }

  function render() {
    root
      .querySelectorAll(".app-screen-outgoing")
      .forEach((node) => node.remove());
    const previous = root.firstElementChild;
    const snapshot =
      previous &&
      !motion.matches &&
      !document.documentElement.classList.contains("is-language-changing")
        ? previous.cloneNode(true)
        : null;
    if (snapshot && canvas)
      snapshot
        .querySelector("canvas")
        ?.getContext("2d")
        ?.drawImage(canvas, 0, 0);
    stop();
    canvas = null;
    ctx = null;
    root.lang = state.language;
    root.dir = state.language === "fa" ? "rtl" : "ltr";
    root.dataset.appScreen = state.screen;
    root.innerHTML = `<div class="app-screen app-screen-${state.screen}">${{ channel, home, lobby, invite }[state.screen](text())}</div>`;
    if (state.screen === "channel") {
      canvas = root.querySelector(".app-dial");
      ctx = canvas.getContext("2d");
      applyVoice();
      resize();
    }
    if (snapshot) {
      snapshot.classList.add("app-screen-outgoing");
      snapshot.setAttribute("aria-hidden", "true");
      snapshot.inert = true;
      root.append(snapshot);
      const distance = state.language === "fa" ? -18 : 18;
      snapshot
        .animate(
          [
            { opacity: 1, transform: "translateX(0)" },
            { opacity: 0, transform: `translateX(${-distance}px)` },
          ],
          { duration: 330, easing: "cubic-bezier(.22,1,.36,1)" },
        )
        .finished.then(() => snapshot.remove())
        .catch(() => snapshot.remove());
      root.firstElementChild.animate(
        [
          { opacity: 0, transform: `translateX(${distance}px)` },
          { opacity: 1, transform: "translateX(0)" },
        ],
        { duration: 450, easing: "cubic-bezier(.22,1,.36,1)" },
      );
    }
  }
  function applyVoice() {
    root.dataset.appVoice = state.voice;
    if (state.screen !== "channel") return;
    const t = text();
    const muted = state.voice === "muted";
    const label =
      state.voice === "self"
        ? t.air
        : state.voice === "peer"
          ? t[peer()]
          : muted
            ? t.muted
            : t.listening;
    replaceText(root.querySelector(".app-readout-label"), label);
    root.querySelector(".app-readout-glyph").innerHTML = muted
      ? icon("microphone-slash")
      : '<i class="app-scope-dot"></i>';
    const mic = root.querySelector(".app-mic-control");
    mic.setAttribute("aria-pressed", String(!muted));
    mic.setAttribute("aria-label", muted ? t.unmuteAction : t.muteAction);
    mic.classList.toggle("app-is-muted", muted);
    root.querySelector(".app-mic-badge").innerHTML = icon(
      muted ? "microphone-slash" : "microphone",
    );
    replaceText(
      root.querySelector(".app-mic-copy strong"),
      muted ? t.muted : t.live,
    );
    replaceText(
      root.querySelector(".app-mic-copy > span"),
      muted ? t.muteHint : t.liveHint,
    );
    replaceText(
      root.querySelector(".app-mic-chip"),
      muted ? t.unmuteAction : t.muteAction,
    );
    root
      .querySelectorAll(".app-screen:not(.app-screen-outgoing) .app-member")
      .forEach((member) => {
        const talking =
          state.voice === "self"
            ? member.dataset.appPerson === state.person
            : state.voice === "peer"
              ? member.dataset.appPerson === peer()
              : false;
        member.classList.toggle("app-member-talking", talking);
        replaceText(
          member.querySelector(".app-member-status > span"),
          talking ? t.speaking : t.connected,
        );
      });
    root.querySelector(".app-scope").setAttribute("aria-label", label);
    previousVoice = state.voice;
    requestDraw();
  }

  function resize() {
    if (!canvas || state.destroyed) return;
    const rect = canvas.getBoundingClientRect();
    const dpr = Math.min(window.devicePixelRatio || 1, 1.5);
    canvas.width = Math.max(1, Math.round(rect.width * dpr));
    canvas.height = Math.max(1, Math.round(rect.height * dpr));
    requestDraw();
  }
  // Geometry and mirrored folding follow AudioVisualizer: 64 bars, hub .48, rim .97.
  // The speech envelope is illustrative; this page never captures audio.
  function draw(now) {
    frame = 0;
    if (!ctx || !canvas || state.destroyed || !state.visible || document.hidden)
      return;
    const dt = lastTime ? Math.min((now - lastTime) / 1000, 1 / 24) : 1 / 60;
    lastTime = now;
    if (!motion.matches) state.clock += dt;
    const time = motion.matches ? 0 : state.clock;
    const width = canvas.width,
      height = canvas.height;
    const scale = Math.min(width, height) / 200;
    const centerX = width / 2,
      centerY = height / 2;
    const radius = 88 * scale,
      hub = radius * 0.48,
      rim = radius * 0.97;
    const stroke = Math.min(7 * scale, ((Math.PI * (hub + rim)) / 64) * 0.5);
    const span = rim - hub - stroke;
    const active = state.voice === "self" || state.voice === "peer";
    const tint =
      state.voice === "self"
        ? [239, 83, 80]
        : state.voice === "peer"
          ? [76, 175, 80]
          : state.voice === "muted"
            ? [139, 147, 157]
            : [245, 133, 63];
    tintCurrent = tintCurrent.map((value, index) =>
      motion.matches
        ? tint[index]
        : value + (tint[index] - value) * (1 - Math.exp(-8 * dt)),
    );
    const rgba = (alpha) =>
      `rgba(${tintCurrent.map(Math.round).join(",")},${alpha})`;
    let sum = 0;
    for (let i = 0; i < 64; i++) {
      const target = active
        ? 0.13 +
          Math.pow(
            Math.max(
              0,
              Math.sin(i * 0.41 - time * 4.8) * 0.43 +
                Math.sin(i * 0.13 + time * 3.7) * 0.31 +
                0.22,
            ),
            0.6,
          ) *
            0.83
        : 0;
      const rate = target > envelopes[i] ? 38 : 7.5;
      envelopes[i] = motion.matches
        ? target
        : envelopes[i] + (target - envelopes[i]) * (1 - Math.exp(-rate * dt));
      sum += envelopes[i];
    }
    const energy = sum / 64;
    ctx.clearRect(0, 0, width, height);
    if (energy > 0.02) {
      const halo = ctx.createRadialGradient(
        centerX,
        centerY,
        hub * 0.5,
        centerX,
        centerY,
        rim + 12 * scale,
      );
      halo.addColorStop(0, rgba(energy * 0.1));
      halo.addColorStop(0.7, rgba(energy * 0.13));
      halo.addColorStop(1, rgba(0));
      ctx.fillStyle = halo;
      ctx.beginPath();
      ctx.arc(centerX, centerY, rim + 12 * scale, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.strokeStyle = rgba(0.14 + energy * 0.25);
    ctx.lineWidth = scale;
    ctx.beginPath();
    ctx.arc(centerX, centerY, rim, 0, Math.PI * 2);
    ctx.stroke();
    ctx.strokeStyle = rgba(0.25 + energy * 0.35);
    ctx.lineWidth = 1.5 * scale;
    ctx.lineCap = "round";
    for (let i = 0; i < 12; i++) {
      const a = (i * Math.PI) / 6,
        start = rim + 3 * scale,
        end = rim + (i % 3 === 0 ? 9 : 5) * scale;
      ctx.beginPath();
      ctx.moveTo(centerX + Math.cos(a) * start, centerY + Math.sin(a) * start);
      ctx.lineTo(centerX + Math.cos(a) * end, centerY + Math.sin(a) * end);
      ctx.stroke();
    }
    const glow = ctx.createRadialGradient(
      centerX,
      centerY,
      0,
      centerX,
      centerY,
      hub,
    );
    glow.addColorStop(0, rgba(0.22));
    glow.addColorStop(1, rgba(0));
    ctx.fillStyle = glow;
    ctx.beginPath();
    ctx.arc(centerX, centerY, hub, 0, Math.PI * 2);
    ctx.fill();
    ctx.strokeStyle = rgba(0.3 + energy * 0.45);
    ctx.lineWidth = scale;
    ctx.beginPath();
    ctx.arc(centerX, centerY, hub, 0, Math.PI * 2);
    ctx.stroke();
    const barGradient = ctx.createRadialGradient(
      centerX,
      centerY,
      hub,
      centerX,
      centerY,
      rim,
    );
    barGradient.addColorStop(0, rgba(0.45));
    barGradient.addColorStop(0.5, rgba(0.95));
    barGradient.addColorStop(1, rgba(1));
    ctx.strokeStyle = barGradient;
    ctx.lineWidth = stroke;
    ctx.lineCap = "round";
    const drift = time * 0.1;
    for (let i = 0; i < 64; i++) {
      const folded = i <= 32 ? i : 64 - i;
      const level = envelopes[Math.min(folded * 2, 63)];
      const shimmer = motion.matches
        ? 0.9
        : 1.8 * (0.5 + 0.5 * Math.sin(drift * 6 - i * 0.4));
      const length = scale + shimmer * scale * (1 - level) + level * span;
      const a = -Math.PI / 2 + drift + (i * Math.PI * 2) / 64,
        start = hub + stroke / 2;
      ctx.beginPath();
      ctx.moveTo(centerX + Math.cos(a) * start, centerY + Math.sin(a) * start);
      ctx.lineTo(
        centerX + Math.cos(a) * (start + length),
        centerY + Math.sin(a) * (start + length),
      );
      ctx.stroke();
    }
    if (!motion.matches) frame = requestAnimationFrame(draw);
  }
  function requestDraw() {
    if (
      !frame &&
      canvas &&
      state.visible &&
      !document.hidden &&
      !state.destroyed
    )
      frame = requestAnimationFrame(draw);
  }
  function stop() {
    if (frame) cancelAnimationFrame(frame);
    frame = 0;
    lastTime = 0;
  }
  function click(event) {
    if (!interactive || state.destroyed) return;
    const target = event.target.closest("[data-app-action]");
    if (!target || !root.contains(target)) return;
    const action = target.dataset.appAction;
    if (action === "mic") {
      state.voice = state.voice === "muted" ? "idle" : "muted";
      applyVoice();
    } else if (action === "create") {
      state.hasGuest = false;
      state.screen = "lobby";
      render();
    } else if (action === "invite") {
      state.screen = "invite";
      render();
    } else if (action === "done" || action === "back") {
      if (action === "done") state.hasGuest = true;
      state.screen = state.screen === "invite" ? "lobby" : "home";
      render();
    } else if (action === "start") {
      state.screen = "channel";
      state.voice = "idle";
      render();
    } else if (action === "leave") {
      state.screen = "home";
      state.voice = "idle";
      render();
    }
    root.dispatchEvent(
      new CustomEvent("app-preview-action", {
        bubbles: true,
        detail: { action, voice: state.voice, screen: state.screen },
      }),
    );
  }
  const visibility = () => {
    if (document.hidden) stop();
    else requestDraw();
  };
  const motionChange = () => {
    stop();
    requestDraw();
  };
  root.addEventListener("click", click);
  document.addEventListener("visibilitychange", visibility);
  motion.addEventListener("change", motionChange);
  window.addEventListener("resize", resize);
  const resizeObserver =
    "ResizeObserver" in window ? new ResizeObserver(resize) : null;
  resizeObserver?.observe(root);
  const observer =
    "IntersectionObserver" in window
      ? new IntersectionObserver((entries) => {
          state.visible = entries[0].isIntersecting;
          if (state.visible) requestDraw();
          else stop();
        })
      : null;
  observer?.observe(root);
  render();
  return {
    setScreen(value) {
      if (!state.destroyed && screens.has(value)) {
        if (state.screen === value) return;
        if (state.screen !== value) {
          if (value === "home") state.hasGuest = false;
          else if (value === "channel") state.hasGuest = true;
        }
        state.screen = value;
        render();
      }
    },
    setVoice(value) {
      if (!state.destroyed && voices.has(value)) {
        state.voice = value;
        applyVoice();
      }
    },
    setLanguage(value) {
      if (!state.destroyed) {
        if (state.language === value) return;
        state.language = value === "en" ? "en" : "fa";
        render();
      }
    },
    destroy() {
      if (state.destroyed) return;
      state.destroyed = true;
      stop();
      resizeObserver?.disconnect();
      observer?.disconnect();
      root.removeEventListener("click", click);
      document.removeEventListener("visibilitychange", visibility);
      motion.removeEventListener("change", motionChange);
      window.removeEventListener("resize", resize);
      root.replaceChildren();
    },
  };
}

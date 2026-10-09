import { mountApp } from "./app-ui.js?v=site-1";
import {
  enter,
  swap,
  replaceText,
  localizeNumbers,
} from "./motion.js?v=site-1";
import { faqItems } from "./content.js";
import { mountEqualizer } from "./equalizer.js?v=site-1";
const $ = (selector) => document.querySelector(selector);
const storage = {
  get(key) {
    try {
      return localStorage.getItem(key);
    } catch {
      return null;
    }
  },
  set(key, value) {
    try {
      localStorage.setItem(key, value);
    } catch {}
  },
};
const queryLang = new URLSearchParams(location.search).get("lang");
let language = ["fa", "en"].includes(queryLang)
  ? queryLang
  : document.documentElement.lang;
let manualChapter = false;
let manualChapterY = 0;
let anchorTween;
let voice = "peer",
  heroMuted = false,
  heroScreen = "channel",
  chapter = 0,
  mode = "bluetooth",
  riding = false,
  storyTrigger,
  motionContext;
let journeyScreen = "home";
const reduced = matchMedia("(prefers-reduced-motion: reduce)");
const t = (fa, en) => (language === "fa" ? fa : en);
const digits = (value) =>
  language === "fa"
    ? String(value).replace(/\d/g, (n) => "۰۱۲۳۴۵۶۷۸۹"[n])
    : String(value);
const self = mountApp($("#heroSelf"), {
  person: "pedram",
  screen: "channel",
  language,
  interactive: true,
});
const peer = mountApp($("#heroPeer"), {
  person: "nazanin",
  screen: "channel",
  language,
});
const journey = mountApp($("#journeyApp"), {
  person: "pedram",
  screen: "home",
  language,
  interactive: true,
});
const apps = [self, peer, journey];
function updateVoice() {
  self.setScreen(heroScreen);
  peer.setScreen("channel");
  const outgoing = heroMuted && voice === "self" ? "idle" : voice;
  self.setVoice(heroMuted ? "muted" : outgoing);
  peer.setVoice(
    outgoing === "self" ? "peer" : outgoing === "peer" ? "self" : "idle",
  );
  $("#heroPair").dataset.voice = voice;
  document
    .querySelectorAll("[data-voice]")
    .forEach((button) =>
      button.setAttribute("aria-pressed", button.dataset.voice === voice),
    );
}
document.querySelectorAll("button[data-voice]").forEach((button) =>
  button.addEventListener("click", () => {
    heroScreen = "channel";
    voice = button.dataset.voice;
    updateVoice();
  }),
);
$("#heroSelf").addEventListener("app-preview-action", (event) => {
  heroScreen = event.detail.screen;
  if (event.detail.action === "mic") {
    heroMuted = event.detail.voice === "muted";
    updateVoice();
  } else if (event.detail.action === "leave") {
    heroMuted = false;
    voice = "idle";
    peer.setVoice("idle");
    $("#heroPair").dataset.voice = "idle";
    document
      .querySelectorAll("button[data-voice]")
      .forEach((button) => button.setAttribute("aria-pressed", "false"));
  }
});
const chapters = [
  {
    title: ["یه اتاق برای خودتون بساز.", "Make a room for your people."],
    description: [
      "اسمش رو انتخاب کن. اینجا جمعِ شما شکل می‌گیره.",
      "Choose a name. This is where your group comes together.",
    ],
    screen: "home",
  },
  {
    title: ["یک اسکن. و رفیقت اینجاست.", "One scan. Your friend is in."],
    description: [
      "دعوت به اتاق رو باز کن. گوشی دوم با «پیوستن با کد دعوت» همون یک کد رو می‌خونه.",
      "Open the room invite. The other phone uses “Join with QR” to scan that one code.",
    ],
    screen: "invite",
  },
  {
    title: ["حالا، صدای هم رو دارید.", "Now you have each other."],
    description: [
      "ارتباط که شروع شد، حرف بزن. توی رابط برنامه می‌بینی کی داره صحبت می‌کنه.",
      "Once connected, speak. The interface shows who is on air.",
    ],
    screen: "channel",
  },
];
function updateJourney(animate = false, setScreen = true) {
  const data = chapters[chapter];
  replaceText(
    $("#journeyTitle"),
    journeyScreen === "lobby"
      ? t("این هم اتاق شما.", "Here’s your room.")
      : data.title[language === "fa" ? 0 : 1],
    animate,
  );
  replaceText(
    $("#journeyDescription"),
    journeyScreen === "lobby"
      ? t(
          "از «دعوت به اتاق» رفیقت رو اضافه کن. بعد از پیوستن، می‌تونید ارتباط رو شروع کنید.",
          "Invite your friend. Once they join, you can start the connection.",
        )
      : data.description[language === "fa" ? 0 : 1],
    animate,
  );
  replaceText(
    $("#journeyCount"),
    digits(String(chapter + 1).padStart(2, "0")),
    animate,
  );
  $("#journeyProduct").dataset.stage = chapter;
  document
    .querySelectorAll("button[data-step]")
    .forEach((button) =>
      button.setAttribute(
        "aria-pressed",
        Number(button.dataset.step) === chapter,
      ),
    );
  if (setScreen) {
    journeyScreen = data.screen;
    journey.setScreen(journeyScreen);
    journey.setVoice(chapter === 2 ? "peer" : "idle");
  }
}
function chooseChapter(index) {
  chapter = index;
  journeyScreen = chapters[index].screen;
  updateJourney(true);
}
$("#journeyApp").addEventListener("app-preview-action", (event) => {
  const { action, screen } = event.detail;
  if (["create", "invite", "start", "done", "back", "leave"].includes(action)) {
    manualChapter = true;
    manualChapterY = scrollY;
    chapter = screen === "invite" ? 1 : screen === "channel" ? 2 : 0;
    journeyScreen = screen;
    updateJourney(true, false);
    if (screen === "channel") journey.setVoice("peer");
  }
});
document.querySelectorAll("button[data-step]").forEach((button) =>
  button.addEventListener("click", () => {
    const index = Number(button.dataset.step);
    if (index === chapter) return;
    manualChapter = true;
    manualChapterY = scrollY;
    chooseChapter(index);
  }),
);

const modes = {
  bluetooth: {
    icon: "bluetooth",
    title: ["دو نفر. دو گوشی. همین.", "Two people. Two phones."],
    description: [
      "وقتی شبکه‌ای دور و برتون نیست، دو اندروید مستقیم با بلوتوث کلاسیک به هم وصل می‌شن.",
      "No network around? Two Android phones connect directly over Bluetooth Classic.",
    ],
    people: ["دو گوشی", "Two phones"],
    range: ["حدود ۱۰ متر در فضای باز", "About 10 m in the open"],
    internet: ["نیاز ندارد", "Not needed"],
    caveat: [
      "برد واقعی به گوشی‌ها و موانع بستگی دارد. بلوتوث رایگان است و حساب نمی‌خواهد.",
      "Real range depends on devices and obstacles. Bluetooth is free and needs no account.",
    ],
  },
  hotspot: {
    icon: "broadcast",
    title: ["شبکه نیست؟ خودمون می‌سازیم.", "No network? Make your own."],
    description: [
      "یه گوشی اندرویدی میزبان می‌شه و بقیه به شبکهٔ همون گوشی وصل می‌شن.",
      "An Android phone hosts, and the others join that phone’s own network.",
    ],
    people: ["به ظرفیت میزبان", "Host-dependent"],
    range: ["برد وای‌فای گوشی", "Phone Wi-Fi coverage"],
    internet: ["نیاز ندارد", "Not needed"],
    caveat: [
      "با اشتراک و میزبانی اندروید ۸ به بالا. تعداد افراد و برد به گوشی میزبان بستگی دارد.",
      "Requires a subscription and Android 8+ for hosting. Group size and range depend on the host.",
    ],
  },
  wifi: {
    icon: "wifi",
    title: ["یک وای‌فای. یک جمع.", "One Wi-Fi. Your whole group."],
    description: [
      "اگه همه روی یه شبکه‌اید، اتصال از همون وای‌فای برقرار می‌شه؛ حتی بدون اینترنت.",
      "On the same network? Connect over that Wi-Fi, even without internet.",
    ],
    people: ["بدون سقف در برنامه", "No app-set limit"],
    range: ["پوشش شبکهٔ مشترک", "Network coverage"],
    internet: ["نیاز ندارد", "Not needed"],
    caveat: [
      "با اشتراک. اتصال وای‌فای مشترک را از گزینهٔ مربوط به آن در اپ انتخاب می‌کنید.",
      "Requires a subscription. Choose the shared Wi-Fi connection option in the app.",
    ],
  },
  browser: {
    icon: "globe",
    title: ["نصب نکرده؟ دعوتش کن.", "No app? Send an invite."],
    description: [
      "با لینک دعوت از کروم یا سافاری وارد کانال می‌شن؛ حتی از راه دور با اینترنت.",
      "Guests join through an invite in Chrome or Safari, including remotely over the internet.",
    ],
    people: ["هر بار یک مهمان", "One guest at a time"],
    range: ["هر جا اینترنت هست", "Anywhere with internet"],
    internet: ["نیاز دارد", "Required"],
    caveat: [
      "با اشتراک میزبان. سرویس عمومی کشف اتصال فقط برای پیدا کردن دستگاه‌هاست؛ صدا مستقیم می‌رود و بعضی شبکه‌های محدود ممکن است اتصال را ببندند.",
      "Requires the host’s subscription. Public STUN helps devices find each other; audio travels directly. Some restricted networks may block the connection.",
    ],
  },
};
function updateMode() {
  const data = modes[mode];
  for (const [id, key] of [
    ["connectionTitle", "title"],
    ["connectionDescription", "description"],
    ["modePeople", "people"],
    ["modeRange", "range"],
    ["modeInternet", "internet"],
    ["modeCaveat", "caveat"],
  ])
    $("#" + id).textContent = data[key][language === "fa" ? 0 : 1];
  $("#connectionIcon").dataset.icon = data.icon;
  $("#connectionNumber").textContent = digits(
    String(Object.keys(modes).indexOf(mode) + 1).padStart(2, "0"),
  );
  $("#connectionPanel").setAttribute("aria-labelledby", "tab-" + mode);
  document.querySelectorAll("[role=tab][data-mode]").forEach((button) => {
    const selected = button.dataset.mode === mode;
    button.setAttribute("aria-selected", selected);
    button.tabIndex = selected ? 0 : -1;
  });
}
document.querySelectorAll("[role=tab][data-mode]").forEach((button) => {
  button.addEventListener("click", () => {
    if (mode === button.dataset.mode) return;
    mode = button.dataset.mode;
    swap($("#connectionPanel"), () => {
      updateMode();
      localizeNumbers(language);
    });
  });
  button.addEventListener("keydown", (event) => {
    if (
      ![
        "ArrowUp",
        "ArrowDown",
        "ArrowLeft",
        "ArrowRight",
        "Home",
        "End",
      ].includes(event.key)
    )
      return;
    event.preventDefault();
    const tabs = [...document.querySelectorAll("[role=tab][data-mode]")];
    let index = tabs.indexOf(button);
    const delta =
      event.key === "ArrowDown"
        ? 1
        : event.key === "ArrowUp"
          ? -1
          : event.key === "ArrowRight"
            ? language === "fa"
              ? -1
              : 1
            : language === "fa"
              ? 1
              : -1;
    index =
      event.key === "Home"
        ? 0
        : event.key === "End"
          ? tabs.length - 1
          : (index + delta + tabs.length) % tabs.length;
    mode = tabs[index].dataset.mode;
    swap($("#connectionPanel"), () => {
      updateMode();
      localizeNumbers(language);
    });
    tabs[index].focus();
  });
});
function updateRide() {
  $("#rideToggle").setAttribute("aria-checked", riding);
  $("#rideSettings").classList.toggle("active", riding);
  const labels = riding
    ? [
        ["روشن", "On"],
        ["فعال", "Active"],
        ["آمادهٔ مسیر", "Road-ready"],
      ]
    : [
        ["خاموش", "Off"],
        ["معمولی", "Standard"],
        ["معمولی", "Standard"],
      ];
  document
    .querySelectorAll(".check-state")
    .forEach((node, index) =>
      replaceText(node, labels[index][language === "fa" ? 0 : 1]),
    );
  replaceText(
    $("#rideStatus"),
    riding
      ? t(
          "دمو روشن است. ارسال با صدا و تنظیمات مناسب مسیر فعال شدند.",
          "Demo on. Voice activation and road settings are enabled.",
        )
      : t(
          "روشنش کن و تغییر تنظیمات رو ببین.",
          "Switch it on to see the settings change.",
        ),
  );
}
$("#rideToggle").addEventListener("click", () => {
  riding = !riding;
  updateRide();
});
function renderFaq() {
  const open = [...$("#faqList").children].map((node, index) =>
    node.open ? index : -1,
  );
  $("#faqList").replaceChildren(
    ...faqItems.map((item, index) => {
      const details = document.createElement("details");
      details.className = "faq-item";
      details.open = open.includes(index);
      const summary = document.createElement("summary"),
        p = document.createElement("p");
      summary.textContent = item[language + "Question"];
      const arrow = document.createElement("span");
      arrow.className = "faq-arrow";
      arrow.setAttribute("aria-hidden", "true");
      summary.prepend(arrow);
      details.dataset.expanded = String(details.open);
      p.textContent = item[language + "Answer"];
      details.append(summary, p);
      summary.addEventListener("click", (event) => {
        event.preventDefault();
        if (details.dataset.animating === "true") return;
        if (reduced.matches) {
          details.open = !details.open;
          details.dataset.expanded = String(details.open);
          return;
        }
        const closing = details.open;
        details.dataset.expanded = String(!closing);
        details.dataset.animating = "true";
        const start = details.getBoundingClientRect().height;
        details.open = true;
        const styles = getComputedStyle(details);
        const end = closing
          ? summary.getBoundingClientRect().height +
            parseFloat(styles.paddingTop) +
            parseFloat(styles.paddingBottom) +
            parseFloat(styles.borderBottomWidth)
          : details.getBoundingClientRect().height;
        details.style.overflow = "hidden";
        const animation = details.animate(
          [{ height: start + "px" }, { height: end + "px" }],
          { duration: 440, easing: "cubic-bezier(.22,1,.36,1)" },
        );
        p.animate(
          [
            {
              opacity: closing ? 1 : 0,
              transform: closing ? "translateY(0)" : "translateY(-6px)",
            },
            {
              opacity: closing ? 0 : 1,
              transform: closing ? "translateY(-6px)" : "translateY(0)",
            },
          ],
          { duration: 330 },
        );
        animation.finished
          .then(() => {
            details.open = !closing;
            details.style.overflow = "";
            details.dataset.animating = "false";
          })
          .catch(() => {
            details.style.overflow = "";
            details.dataset.animating = "false";
          });
      });
      return details;
    }),
  );
}
function applyTheme() {
  document.documentElement.dataset.theme = "dark";
  document.querySelector("meta[name=theme-color]").content = "#0d1913";
}
function applyLanguage() {
  document.documentElement.lang = language;
  document.documentElement.dir = language === "fa" ? "rtl" : "ltr";
  document
    .querySelectorAll("[data-fa][data-en]")
    .forEach((node) => (node.textContent = node.dataset[language]));
  $("#langToggle").textContent = t("انگلیسی", "Persian");
  $("#langToggle").setAttribute(
    "aria-label",
    t("نمایش به انگلیسی", "View in Persian"),
  );
  $("#langToggle").lang = language === "fa" ? "en" : "fa";
  storage.set("tark_lang", language);
  document.querySelector("link[rel=canonical]").href = "https://tarkk.ir" + (language === "fa" ? "/fa/" : "/");
  document.querySelector('meta[property="og:url"]').content = document.querySelector("link[rel=canonical]").href;
  const ld = document.querySelector('script[type="application/ld+json"]');
  if (ld) {
    const data = JSON.parse(ld.textContent);
    const pageUrl = document.querySelector("link[rel=canonical]").href;
    for (const entry of data["@graph"]) {
      if (entry["@type"] === "Organization") continue;
      entry.inLanguage = language;
      entry["@id"] = pageUrl + entry["@id"].slice(entry["@id"].indexOf("#"));
      if (entry.url) entry.url = pageUrl;
      if (entry.description) entry.description = document.querySelector("meta[name=description]").dataset[language === "fa" ? "metaFa" : "metaEn"];
      if (entry["@type"] === "WebSite") entry.name = t("تَرک", "Tarkk");
      if (entry["@type"] === "FAQPage") entry.mainEntity = faqItems.map(item => ({ "@type": "Question", name: item[language + "Question"], acceptedAnswer: { "@type": "Answer", text: item[language + "Answer"] } }));
    }
    ld.textContent = JSON.stringify(data);
  }
  for (const node of document.querySelectorAll("[data-meta-fa][data-meta-en]")) node.content = node.dataset[language === "fa" ? "metaFa" : "metaEn"];
  document.title = document.querySelector('meta[property="og:title"]').content;
  document
    .querySelectorAll("[data-legal]")
    .forEach(
      (link) =>
        (link.href =
          (language === "fa" ? "/fa/" : "/") + link.dataset.legal),
    );
  $(".nav").setAttribute("aria-label", t("منوی اصلی", "Main navigation"));
  $(".brand").setAttribute("aria-label", t("تَرک", "Tarkk"));
  $("#sceneFit").setAttribute(
    "aria-label",
    t("گوشی تَرک کنار تجهیزات سفر", "Tarkk phone alongside riding gear"),
  );
  $(".scene-photo").alt = t(
    "گوشی، کلاه و دستکش موتورسواری روی میز آماده‌سازی سفر",
    "A phone, helmet and riding gloves on a travel preparation table",
  );
  $("#handshake").setAttribute(
    "aria-label",
    t("چطور کار می‌کند", "How it works"),
  );
  $("#menuToggle").setAttribute("aria-label", t("منو", "Menu"));
  $(".voice-options").setAttribute(
    "aria-label",
    t("نمایش مکالمه", "Conversation demo"),
  );
  $(".journey-steps").setAttribute(
    "aria-label",
    t("مراحل اتصال", "Connection steps"),
  );
  $(".connection-tabs").setAttribute(
    "aria-label",
    t("روش‌های اتصال", "Connection methods"),
  );
  apps.forEach((app) => app.setLanguage(language));
  updateVoice();
  updateJourney(false, false);
  updateMode();
  updateRide();
  updateMusic();
  renderFaq();
  applyTheme();
  localizeNumbers(language);
  document.dispatchEvent(
    new CustomEvent("preview-language-applied", { detail: { language } }),
  );
  window.ScrollTrigger?.refresh();
}
$("#langToggle").addEventListener("click", () => {
  if (document.documentElement.classList.contains("is-language-changing"))
    return;
  anchorTween?.kill();
  document.documentElement.dataset.anchorScrolling = "false";
  manualChapter = true;
  manualChapterY = scrollY;
  const nextLanguage = language === "fa" ? "en" : "fa";
  storage.set("tark_lang", nextLanguage);
  const url = new URL(location.href);
  url.pathname = nextLanguage === "fa" ? "/fa/" : "/";
  url.searchParams.delete("lang");
  const commit = () => {
    history.replaceState(null, "", url);
    language = nextLanguage;
    applyLanguage();
  };
  if (window.transitionPreviewLanguage)
    window.transitionPreviewLanguage(commit);
  else commit();
});
let menuAnimation;
function closeMenu() {
  const nav = $("#navLinks");
  $("#menuToggle").setAttribute("aria-expanded", "false");
  menuAnimation?.cancel();
  if (reduced.matches || !matchMedia("(max-width:767px)").matches) {
    nav.classList.remove("open");
    return;
  }
  menuAnimation = nav.animate(
    [
      { opacity: 1, transform: "translateY(0)" },
      { opacity: 0, transform: "translateY(-12px)" },
    ],
    { duration: 280, easing: "cubic-bezier(.22,1,.36,1)" },
  );
  menuAnimation.finished
    .then(() => nav.classList.remove("open"))
    .catch(() => {});
}
$("#menuToggle").addEventListener("click", () => {
  if ($("#menuToggle").getAttribute("aria-expanded") === "true") {
    closeMenu();
    return;
  }
  menuAnimation?.cancel();
  $("#navLinks").classList.add("open");
  $("#menuToggle").setAttribute("aria-expanded", "true");
  enter(document.querySelectorAll("#navLinks"), -12);
  $("#navLinks a").focus();
});
document.querySelectorAll("#navLinks a").forEach((link) =>
  link.addEventListener("click", () => {
    closeMenu();
  }),
);
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && $("#navLinks").classList.contains("open")) {
    closeMenu();
    $("#menuToggle").focus();
  }
});

// Optional music preview, synthesized locally only after a user gesture.
let audioContext,
  equalizerController,
  musicGain,
  musicTimer,
  musicPlaying = false,
  audioAction = 0,
  noteIndex = 0;
const notes = [220, 277.18, 329.63, 440, 369.99, 329.63, 277.18, 246.94];
async function ensureAudio() {
  const Audio = window.AudioContext || window.webkitAudioContext;
  if (!Audio) throw new Error("Audio unavailable");
  audioContext ??= new Audio();
  if (audioContext.state === "suspended") await audioContext.resume();
  if (!musicGain) {
    musicGain = audioContext.createGain();
    musicGain.gain.value = Number($("#musicMix").value) / 100;
    musicGain.connect(audioContext.destination);
  }
}
function tick() {
  if (!musicPlaying || !audioContext) return;
  const now = audioContext.currentTime,
    osc = audioContext.createOscillator(),
    gain = audioContext.createGain();
  osc.type = "sine";
  osc.frequency.value = notes[noteIndex++ % notes.length];
  gain.gain.setValueAtTime(0, now);
  gain.gain.linearRampToValueAtTime(0.12, now + 0.03);
  gain.gain.exponentialRampToValueAtTime(0.0001, now + 0.42);
  osc.connect(gain);
  gain.connect(musicGain);
  osc.start(now);
  osc.stop(now + 0.45);
  osc.onended = () => {
    osc.disconnect();
    gain.disconnect();
  };
}
function updateMusic() {
  $("#musicPlay").setAttribute("aria-pressed", musicPlaying);
  replaceText(
    $("#musicPlayLabel"),
    musicPlaying ? t("توقف دمو", "Stop demo") : t("پخش دمو", "Play demo"),
  );
  $("#musicPlay .icon").dataset.icon = musicPlaying ? "pause" : "play";
  $("#equalizer").classList.toggle("playing", musicPlaying);
  equalizerController?.setPlaying(musicPlaying);
  $("#mixValue").textContent = digits($("#musicMix").value) + t("٪", "%");
  $("#musicMix").setAttribute(
    "aria-valuetext",
    digits($("#musicMix").value) + t(" درصد", " percent"),
  );
}
function stopMusic() {
  audioAction++;
  musicPlaying = false;
  clearInterval(musicTimer);
  musicTimer = null;
  if (musicGain && audioContext)
    musicGain.gain.setTargetAtTime(0, audioContext.currentTime, 0.015);
  updateMusic();
}
$("#musicPlay").addEventListener("click", async () => {
  if (musicPlaying) {
    stopMusic();
    return;
  }
  const action = ++audioAction;
  try {
    await ensureAudio();
    if (action !== audioAction || document.hidden) return;
    musicPlaying = true;
    noteIndex = 0;
    musicGain.gain.setTargetAtTime(
      Number($("#musicMix").value) / 100,
      audioContext.currentTime,
      0.02,
    );
    updateMusic();
    tick();
    musicTimer = setInterval(tick, 245);
  } catch {
    $("#musicPlayLabel").textContent = t(
      "پخش صدا در دسترس نیست",
      "Audio unavailable",
    );
  }
});
$("#musicMix").addEventListener("input", () => {
  if (musicGain && audioContext && musicPlaying)
    musicGain.gain.setTargetAtTime(
      Number($("#musicMix").value) / 100,
      audioContext.currentTime,
      0.025,
    );
  updateMusic();
});
for (let index = 0; index < 38; index++) {
  const bar = document.createElement("i");
  bar.style.setProperty(
    "--height",
    16 + Math.abs(Math.sin(index * 0.73)) * 85 + "px",
  );
  bar.style.setProperty("--delay", -index * 0.08 + "s");
  $("#equalizer").append(bar);
}
equalizerController = mountEqualizer($("#equalizer"));
window.addEventListener("blur", stopMusic);
document.addEventListener("visibilitychange", () => {
  if (document.hidden) stopMusic();
});
applyLanguage();
chooseChapter(0);
if (window.gsap && window.ScrollTrigger) {
  const { gsap, ScrollTrigger } = window;
  gsap.registerPlugin(ScrollTrigger);
  motionContext = gsap.matchMedia();
  motionContext.add(
    "(min-width:1024px) and (min-height:640px) and (prefers-reduced-motion:no-preference)",
    () => {
      storyTrigger = ScrollTrigger.create({
        trigger: "#handshake",
        start: "top 82px",
        end: "bottom bottom",
        invalidateOnRefresh: true,
        onUpdate: (s) => {
          if (manualChapter) {
            if (
              document.documentElement.dataset.anchorScrolling === "true" ||
              Math.abs(scrollY - manualChapterY) < 3
            )
              return;
            manualChapter = false;
          }
          const next = Math.min(2, Math.floor(s.progress * 3));
          if (next !== chapter || journeyScreen !== chapters[next].screen) {
            chooseChapter(next);
          }
        },
      });
      return () => {
        storyTrigger?.kill();
        storyTrigger = null;
      };
    },
  );
  document.fonts?.ready.then(() => ScrollTrigger.refresh());
}
const resumeScrollChapters = () => {
  anchorTween?.kill();
  document.documentElement.dataset.anchorScrolling = "false";
  manualChapter = false;
};
window.addEventListener("wheel", resumeScrollChapters, { passive: true });
window.addEventListener("touchmove", resumeScrollChapters, { passive: true });
window.addEventListener("keydown", (event) => {
  if (
    ["PageDown", "PageUp", "ArrowDown", "ArrowUp", "Home", "End", " "].includes(
      event.key,
    ) &&
    !event.target.closest("button,input,summary")
  )
    resumeScrollChapters();
});
document.querySelectorAll('a[href^="#"]').forEach((link) =>
  link.addEventListener("click", (event) => {
    const hash = link.getAttribute("href"),
      target = document.querySelector(hash);
    if (!target || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || event.button !== 0) return;
    event.preventDefault();
    anchorTween?.kill();
    const destination =
      hash === "#handshake" && storyTrigger
        ? storyTrigger.start + 1
        : hash === "#top" || hash === "#main"
          ? 0
          : Math.max(0, target.getBoundingClientRect().top + scrollY - 82);
    manualChapter = true;
    if (hash === "#handshake") chooseChapter(0);
    const complete = () => {
      manualChapter = false;
      document.documentElement.dataset.anchorScrolling = "false";
      history.replaceState(null, "", hash);
      window.ScrollTrigger?.update();
    };
    if (reduced.matches || !window.gsap) {
      scrollTo({ top: destination, behavior: "instant" });
      complete();
      return;
    }
    const position = { y: scrollY };
    document.documentElement.dataset.anchorScrolling = "true";
    anchorTween = window.gsap.to(position, {
      y: destination,
      duration: Math.min(1.45, 0.7 + Math.abs(destination - scrollY) / 2300),
      ease: "power3.inOut",
      onUpdate: () => scrollTo({ top: position.y, behavior: "instant" }),
      onComplete: complete,
    });
  }),
);
const reveal = new IntersectionObserver(
  (entries) =>
    entries.forEach((entry) => {
      if (entry.isIntersecting) {
        entry.target.classList.add("visible");
        reveal.unobserve(entry.target);
      }
    }),
  { threshold: 0.08 },
);
document
  .querySelectorAll(
    ".section-head,.connection-layout,.ride-copy,.ride-settings,.music-copy,.music-demo,.tech-numbers,.plans",
  )
  .forEach((node) => {
    node.classList.add("reveal");
    if (reduced.matches) node.classList.add("visible");
    else reveal.observe(node);
  });
document.documentElement.classList.add("js-ready");
window.addEventListener("pagehide", (event) => {
  anchorTween?.kill();
  stopMusic();
  if (!event.persisted) {
    motionContext?.revert();
    apps.forEach((app) => app.destroy());
    reveal.disconnect();
    audioContext?.close();
    equalizerController?.destroy();
  }
});
window.addEventListener("pageshow", (event) => {
  if (event.persisted) window.ScrollTrigger?.refresh();
});

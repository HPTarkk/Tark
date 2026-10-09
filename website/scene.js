import { replaceText } from "./motion.js?v=site-1";
import { restoreArrivalAnchor } from "./page-transitions.js?v=site-1";
const $ = (selector) => document.querySelector(selector);
const stage = $("#rideStage"),
  fit = $("#sceneFit"),
  camera = $("#sceneCamera"),
  drift = $("#sceneDrift");
const header = $(".site-header"),
  peer = $("#heroPeer"),
  status = $("#scenePeerStatus"),
  badge = $(".scene-live");
const reduced = matchMedia("(prefers-reduced-motion: reduce)"),
  mobile = matchMedia("(max-width:1023px)");
const gsap = window.gsap,
  ScrollTrigger = window.ScrollTrigger;
let motion, headerTrigger, introTimeline, languageTimeline;
function fitScene() {
  const rect = stage.getBoundingClientRect();
  const imageHeight = mobile.matches
    ? innerWidth <= 767
      ? 580
      : 620
    : rect.height -
      (parseFloat(
        getComputedStyle(stage).getPropertyValue("--hero-footer-height"),
      ) || 96);
  const scale = mobile.matches
    ? imageHeight / 941
    : Math.max(rect.width / 1672, imageHeight / 941);
  fit.style.setProperty("--scene-fit", scale);
  fit.style.setProperty(
    "--scene-offset",
    mobile.matches
      ? `${(document.documentElement.lang === "en" ? -196 : 196) * scale}px`
      : "0px",
  );
}
function updateStatus() {
  const english = document.documentElement.lang === "en",
    talking = peer.dataset.appVoice === "self";
  const label = talking
    ? english
      ? "Nazanin is on air"
      : "نازنین روی آنتن است"
    : english
      ? "Nazanin is listening"
      : "نازنین دارد گوش می‌دهد";
  if (status.textContent !== label) {
    replaceText(status, label);
  }
  badge.dataset.speaking = talking;
}
function scrollHeader() {
  header.classList.toggle("has-scrolled", scrollY > 45);
}
const observer = new ResizeObserver(fitScene);
observer.observe(stage);
const voiceObserver = new MutationObserver(updateStatus);
voiceObserver.observe(peer, {
  attributes: true,
  attributeFilter: ["data-app-voice"],
});
document.addEventListener("preview-language-applied", () => {
  fitScene();
  updateStatus();
});
window.addEventListener("resize", fitScene, { passive: true });
fitScene();
updateStatus();
scrollHeader();
if (gsap && ScrollTrigger) {
  gsap.registerPlugin(ScrollTrigger);
  headerTrigger = ScrollTrigger.create({
    start: 45,
    end: "max",
    onUpdate: scrollHeader,
    onRefresh: scrollHeader,
  });
  motion = gsap.matchMedia();
  motion.add(
    "(min-width:1024px) and (min-height:640px) and (prefers-reduced-motion:no-preference)",
    () => {
      const timeline = gsap.timeline({
        scrollTrigger: {
          trigger: "#top",
          pin: "#rideStage",
          start: "top top",
          end: () => `+=${Math.round(innerHeight * 0.7)}`,
          scrub: 1,
          refreshPriority: 1,
          invalidateOnRefresh: true,
        },
      });
      timeline.to(camera, { scale: 1.12, y: 6, ease: "none" }, 0);
      const moveX = gsap.quickTo(drift, "x", {
          duration: 0.7,
          ease: "power3.out",
        }),
        moveY = gsap.quickTo(drift, "y", { duration: 0.7, ease: "power3.out" });
      const move = (event) => {
        if (document.documentElement.classList.contains("is-language-changing"))
          return;
        const r = stage.getBoundingClientRect();
        moveX(((event.clientX - r.left) / r.width - 0.5) * 8);
        moveY(((event.clientY - r.top) / r.height - 0.5) * 5);
      };
      const leave = () => {
        moveX(0);
        moveY(0);
      };
      stage.addEventListener("pointermove", move);
      stage.addEventListener("pointerleave", leave);
      return () => {
        stage.removeEventListener("pointermove", move);
        stage.removeEventListener("pointerleave", leave);
        timeline.scrollTrigger?.kill();
        timeline.kill();
      };
    },
  );
}

// The texture is mirrored; the independent live screen projection keeps text readable.
window.transitionPreviewLanguage = (commit) => {
  const root = document.documentElement;
  if (root.classList.contains("is-language-changing")) return;
  const y = scrollY,
    anchors = [...document.querySelectorAll("main>section, #routeBridge")];
  const anchor =
    anchors.filter((node) => node.getBoundingClientRect().top <= 95).at(-1) ||
    $("#top");
  const anchorTop = anchor.getBoundingClientRect().top;
  root.classList.add("is-language-changing");
  $("#langToggle").setAttribute("aria-busy", "true");
  const apply = () => {
    commit();
    fitScene();
    ScrollTrigger?.refresh();
    const nextY = y + anchor.getBoundingClientRect().top - anchorTop;
    scrollTo({ top: y < 10 ? 0 : Math.max(0, nextY), behavior: "instant" });
    scrollHeader();
  };
  const finish = () => {
    root.classList.remove("is-language-changing");
    $("#langToggle").removeAttribute("aria-busy");
  };
  if (reduced.matches || !gsap) {
    apply();
    finish();
    return;
  }
  const direction = root.lang === "fa" ? -1 : 1;
  gsap.set(".language-curtain", { visibility: "visible" });
  gsap.set(".language-panel", { xPercent: direction * 102 });
  languageTimeline = gsap.timeline({
    onComplete: () => {
      gsap.set(".language-curtain", { visibility: "hidden" });
      gsap.set(".ride-hero-copy>*", { clearProps: "transform,opacity" });
      gsap.set("#sceneIntro", { clearProps: "transform,opacity" });
      finish();
    },
  });
  languageTimeline
    .to(
      ".language-panel",
      { xPercent: 0, duration: 0.58, stagger: 0.055, ease: "power3.inOut" },
      0,
    )
    .to(
      ".ride-hero-copy>*",
      { x: direction * 32, opacity: 0, duration: 0.3, stagger: 0.025 },
      0,
    )
    .call(apply, [], 0.69)
    .set("#sceneIntro", { scale: 1.07, opacity: 0.5 }, 0.7)
    .set(".ride-hero-copy>*", { x: -direction * 40, opacity: 0 }, 0.7)
    .to(
      ".language-panel",
      {
        xPercent: -direction * 102,
        duration: 0.72,
        stagger: 0.05,
        ease: "power3.inOut",
      },
      0.77,
    )
    .to(
      "#sceneIntro",
      { scale: 1, opacity: 1, duration: 1, ease: "power3.out" },
      0.85,
    )
    .to(
      ".ride-hero-copy>*",
      { x: 0, opacity: 1, duration: 0.72, stagger: 0.055, ease: "power3.out" },
      1.02,
    );
};

async function revealPage() {
  const loader = $("#pageLoader"),
    progress = $("#loadProgress");
  const tasks = [
    document.fonts.ready,
    $(".scene-photo").decode(),
    ...["/assets/rider.webp", "/assets/woman-rider.webp"].map(
      (src) =>
        new Promise((resolve) => {
          const image = new Image();
          image.onload = image.onerror = resolve;
          image.src = src;
        }),
    ),
  ];
  let done = 0;
  await Promise.allSettled(
    tasks.map(async (task) => {
      try {
        await task;
      } finally {
        done++;
        progress.style.setProperty("--load-progress", done / tasks.length);
        $("#loadPercent").textContent =
          (document.documentElement.lang === "fa"
            ? String(Math.round((done / tasks.length) * 100)).replace(
                /\d/g,
                (digit) => "۰۱۲۳۴۵۶۷۸۹"[digit],
              )
            : String(Math.round((done / tasks.length) * 100))) +
          (document.documentElement.lang === "fa" ? "٪" : "%");
      }
    }),
  );
  fitScene();
  ScrollTrigger?.refresh();
  scrollTo({ top: 0, behavior: "instant" });
  rootReady();
  fitScene();
  ScrollTrigger?.refresh();
  scrollTo({ top: 0, behavior: "instant" });
  if (reduced.matches || !gsap) {
    loader.remove();
    restoreArrivalAnchor();
    document.documentElement.classList.add("intro-complete");
    return;
  }
  gsap.set("#sceneIntro", { scale: 1.11, opacity: 0.45 });
  gsap.set(".ride-hero-copy>*", { y: 28, opacity: 0 });
  gsap.set(".site-header", { y: -20, opacity: 0 });
  introTimeline = gsap.timeline({
    onComplete: () => {
      loader.remove();
      gsap.set("#sceneIntro, .ride-hero-copy>*, .site-header", {
        clearProps: "transform,opacity",
      });
      document.documentElement.classList.add("intro-complete");
      restoreArrivalAnchor();
    },
  });
  introTimeline
    .to(
      ".loader-center, .loader-kicker",
      { y: -25, opacity: 0, duration: 0.38, ease: "power2.in" },
      0.3,
    )
    .to(
      ".loader-panel:first-child",
      { yPercent: -102, duration: 1.15, ease: "power3.inOut" },
      0.5,
    )
    .to(
      ".loader-panel:last-child",
      { yPercent: 102, duration: 1.15, ease: "power3.inOut" },
      0.5,
    )
    .to(
      "#sceneIntro",
      { scale: 1, opacity: 1, duration: 1.5, ease: "power3.out" },
      0.62,
    )
    .to(".site-header", { y: 0, opacity: 1, duration: 0.65 }, 0.95)
    .to(
      ".ride-hero-copy>*",
      { y: 0, opacity: 1, duration: 0.85, stagger: 0.07, ease: "power3.out" },
      0.9,
    );
}
function rootReady() {
  document.documentElement.classList.remove("is-booting");
  document.documentElement.classList.add("page-loaded");
}
revealPage().catch(() => {
  rootReady();
  $("#pageLoader")?.remove();
  restoreArrivalAnchor();
});
window.addEventListener("pagehide", (event) => {
  if (!event.persisted) {
    observer.disconnect();
    voiceObserver.disconnect();
    motion?.revert();
    headerTrigger?.kill();
    introTimeline?.kill();
    languageTimeline?.kill();
    window.removeEventListener("resize", fitScene);
  }
});
window.addEventListener("pageshow", (event) => {
  if (!event.persisted) return;
  introTimeline?.progress(1);
  languageTimeline?.progress(1);
  gsap?.set(".language-curtain", { visibility: "hidden" });
  gsap?.set("#sceneIntro,.ride-hero-copy>*,.site-header", { clearProps: "transform,opacity" });
});

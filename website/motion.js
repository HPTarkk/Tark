const reduced = matchMedia("(prefers-reduced-motion: reduce)");
const easing = "cubic-bezier(.22,1,.36,1)";
const textJobs = new WeakMap();
const panelJobs = new WeakMap();
export function replaceText(node, value, animate = true) {
  const text = String(value),
    previous = textJobs.get(node);
  const languageChanging = document.documentElement.classList.contains(
    "is-language-changing",
  );
  if (
    previous?.target === text &&
    !languageChanging &&
    (node.textContent === text || previous.animation?.playState === "running")
  )
    return;
  const opacity = Number(getComputedStyle(node).opacity);
  previous?.animation?.cancel();
  const job = { target: text, animation: null };
  textJobs.set(node, job);
  if (
    !animate ||
    reduced.matches ||
    document.documentElement.classList.contains("is-language-changing") ||
    !node.textContent.trim()
  ) {
    node.textContent = text;
    return;
  }
  if (node.textContent === text) return;
  const show = () => {
    if (textJobs.get(node) !== job) return;
    node.textContent = text;
    job.animation?.cancel();
    job.animation = node.animate(
      [
        { opacity: 0, transform: "translateY(7px)" },
        { opacity: 1, transform: "translateY(0)" },
      ],
      { duration: 380, easing, fill: "both" },
    );
    job.animation.finished
      .then(() => {
        if (textJobs.get(node) === job) job.animation.cancel();
      })
      .catch(() => {});
  };
  if (opacity < 0.05) {
    show();
    return;
  }
  job.animation = node.animate(
    [
      { opacity, transform: "translateY(0)" },
      { opacity: 0, transform: "translateY(-5px)" },
    ],
    { duration: 160, easing, fill: "forwards" },
  );
  job.animation.finished.then(show).catch(() => {});
}
export function enter(nodes, distance = 12) {
  if (
    reduced.matches ||
    document.documentElement.classList.contains("is-language-changing")
  )
    return;
  [...nodes].forEach((node, index) => {
    node.getAnimations().forEach((animation) => animation.cancel());
    node.animate(
      [
        { opacity: 0.15, transform: `translateY(${distance}px)` },
        { opacity: 1, transform: "translateY(0)" },
      ],
      { duration: 440, delay: index * 25, easing, fill: "backwards" },
    );
  });
}
export function swap(container, update) {
  const old = panelJobs.get(container);
  old?.animations.forEach((animation) => animation.cancel());
  const job = { animations: [] };
  panelJobs.set(container, job);
  container
    .querySelectorAll(".motion-snapshot")
    .forEach((node) => node.remove());
  if (
    reduced.matches ||
    document.documentElement.classList.contains("is-language-changing")
  ) {
    update();
    return;
  }
  const beforeHeight = container.getBoundingClientRect().height;
  job.animations = [...container.children].map((node) =>
    node.animate(
      [
        { opacity: 1, transform: "translateY(0)" },
        { opacity: 0, transform: "translateY(-6px)" },
      ],
      { duration: 170, easing, fill: "forwards" },
    ),
  );
  Promise.allSettled(
    job.animations.map((animation) => animation.finished),
  ).then(() => {
    if (panelJobs.get(container) !== job) return;
    update();
    job.animations.forEach((animation) => animation.cancel());
    const afterHeight = container.getBoundingClientRect().height;
    if (Math.abs(beforeHeight - afterHeight) > 2)
      container.animate(
        [{ height: beforeHeight + "px" }, { height: afterHeight + "px" }],
        { duration: 420, easing },
      );
    enter(container.children, 10);
  });
}
export function localizeNumbers(language) {
  const walker = document.createTreeWalker(
    document.querySelector("main"),
    NodeFilter.SHOW_TEXT,
  );
  let node;
  while ((node = walker.nextNode())) {
    if (
      node.parentElement.closest(
        "script,style,.motion-snapshot,.app-screen-outgoing",
      )
    )
      continue;
    const latin = node.textContent.replace(/[۰-۹]/g, (digit) =>
      String("۰۱۲۳۴۵۶۷۸۹".indexOf(digit)),
    );
    const translated =
      language === "fa"
        ? latin.replace(/\d/g, (digit) => "۰۱۲۳۴۵۶۷۸۹"[digit])
        : latin;
    if (node.textContent !== translated) node.textContent = translated;
  }
}

export function mountEqualizer(root) {
  const bars = [...root.children],
    reduced = matchMedia("(prefers-reduced-motion:reduce)");
  const baseline = bars.map(
    (bar, index) => 0.16 + Math.abs(Math.sin(index * 0.73)) * 0.66,
  );
  const levels = [...baseline];
  let active = false,
    frame = 0,
    last = 0,
    time = 0,
    revision = 0;
  root.dataset.state = "idle";
  bars.forEach((bar, index) => {
    bar.style.setProperty("--idle", baseline[index]);
    bar.style.transform = `scaleY(${baseline[index]})`;
  });
  function draw(now) {
    frame = 0;
    if (!active || document.hidden) return;
    const dt = last ? Math.min((now - last) / 1000, 0.05) : 1 / 60;
    last = now;
    time += dt;
    bars.forEach((bar, index) => {
      const wave =
        Math.sin(time * 5.1 + index * 0.46) * 0.35 +
        Math.sin(time * 8.7 - index * 0.23) * 0.23 +
        Math.sin(time * 2.8 + index * 0.8) * 0.17;
      const target = 0.17 + Math.min(0.8, Math.abs(wave) * 1.12);
      levels[index] += (target - levels[index]) * (1 - Math.exp(-13 * dt));
      bar.style.transform = `scaleY(${levels[index]})`;
    });
    frame = requestAnimationFrame(draw);
  }
  function settle() {
    const job = ++revision,
      animations = [];
    root.dataset.state = reduced.matches ? "idle" : "settling";
    cancelAnimationFrame(frame);
    frame = 0;
    last = 0;
    bars.forEach((bar, index) => {
      const from = levels[index];
      levels[index] = baseline[index];
      bar.getAnimations().forEach((animation) => animation.cancel());
      bar.style.transform = `scaleY(${baseline[index]})`;
      if (!reduced.matches)
        animations.push(
          bar.animate(
            [
              { transform: `scaleY(${from})` },
              { transform: `scaleY(${baseline[index]})` },
            ],
            { duration: 580, easing: "cubic-bezier(.22,1,.36,1)" },
          ),
        );
    });
    Promise.allSettled(animations.map((animation) => animation.finished)).then(
      () => {
        if (revision === job && !active) root.dataset.state = "idle";
      },
    );
  }
  function setPlaying(value) {
    if (active === value) return;
    revision++;
    bars.forEach((bar, index) => {
      const matrix = getComputedStyle(bar).transform;
      if (matrix.startsWith("matrix("))
        levels[index] = Number(matrix.slice(7, -1).split(",")[3]);
      bar.style.transform = `scaleY(${levels[index]})`;
    });
    active = value;
    bars.forEach((bar) =>
      bar.getAnimations().forEach((animation) => animation.cancel()),
    );
    if (active && !reduced.matches) {
      root.dataset.state = "playing";
      last = 0;
      frame = requestAnimationFrame(draw);
    } else settle();
  }
  const motionChange = () => {
    if (active) {
      cancelAnimationFrame(frame);
      last = 0;
      if (!reduced.matches) frame = requestAnimationFrame(draw);
      else settle();
    }
  };
  reduced.addEventListener("change", motionChange);
  return {
    setPlaying,
    destroy() {
      active = false;
      cancelAnimationFrame(frame);
      bars.forEach((bar) =>
        bar.getAnimations().forEach((animation) => animation.cancel()),
      );
      reduced.removeEventListener("change", motionChange);
    },
  };
}

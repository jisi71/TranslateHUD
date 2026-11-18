(() => {
  const tablist = document.querySelector(".feature-tabs");
  const tabs = [...tablist.querySelectorAll("a")];
  const panels = tabs.map(tab => document.getElementById(tab.hash.slice(1)));

  function select(index) {
    tabs.forEach((tab, position) => {
      const active = position === index;
      tab.setAttribute("aria-selected", String(active));
      tab.tabIndex = active ? 0 : -1;
      panels[position].inert = !active;
    });
  }

  function selectFromHash() {
    const index = tabs.findIndex(tab => tab.hash === location.hash);
    select(index < 0 ? 0 : index);
  }

  function visit(index) {
    select(index);
    const hash = tabs[index].hash;
    if (location.hash !== hash) history.pushState(null, "", hash);
  }

  tablist.setAttribute("role", "tablist");
  tabs.forEach((tab, index) => {
    const panel = panels[index];
    tab.id = panel.id + "-tab";
    tab.setAttribute("role", "tab");
    tab.setAttribute("aria-controls", panel.id);
    panel.setAttribute("role", "tabpanel");
    panel.setAttribute("aria-labelledby", tab.id);
    panel.tabIndex = 0;
    tab.addEventListener("click", event => {
      if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      event.preventDefault();
      visit(index);
    });
    tab.addEventListener("keydown", event => {
      const targets = {
        ArrowLeft: (index + tabs.length - 1) % tabs.length,
        ArrowRight: (index + 1) % tabs.length,
        Home: 0,
        End: tabs.length - 1
      };
      if (!(event.key in targets)) return;
      event.preventDefault();
      const next = targets[event.key];
      visit(next);
      tabs[next].focus();
    });
  });
  selectFromHash();
  window.addEventListener("hashchange", selectFromHash);

  const hero = document.querySelector(".hero-art");
  const scenes = [...hero.querySelectorAll(".hero-scene")];
  const captions = [...hero.querySelectorAll("[data-caption]")];
  const basePanel = scenes[0].querySelector(".hud-panel");
  const cursor = scenes[0].querySelector(".capture-cursor");
  for (const scene of scenes.slice(1)) {
    const panel = basePanel.cloneNode(true);
    const source = document.createElement("div");
    source.className = "hud-source";
    const table = scene.querySelector(".schedule-grid");
    source.append(table ? table.cloneNode(true) : scene.querySelector("mark").textContent);
    panel.querySelector(".hud-source").replaceWith(source);
    const result = document.createElement("div");
    result.className = "hud-out";
    result.append(scene.querySelector(".panel-result").content.cloneNode(true));
    panel.querySelector(".hud-out").replaceWith(result);
    scene.append(panel);
    if (table) scene.querySelector(".capture-marquee").append(cursor.cloneNode(true));
  }

  const toggle = hero.querySelector(".demo-toggle");
  const replay = hero.querySelector(".replay");
  const motion = window.matchMedia("(prefers-reduced-motion: reduce)");
  const resultHold = 2000;
  let active = 0;
  let paused = false;
  let inView = !("IntersectionObserver" in window);
  let effects = [];

  function updatePlayback() {
    const playing = inView && !document.hidden && !paused;
    for (const effect of effects) {
      if (playing) {
        if (effect.playState === "paused") effect.play();
      } else if (effect.playState === "running") {
        effect.pause();
      }
    }
    toggle.querySelector(".play-label").hidden = !paused;
    toggle.querySelector(".pause-label").hidden = paused;
  }

  function show(index) {
    effects.forEach(effect => effect.cancel());
    effects = [];
    active = index;
    scenes.forEach((scene, i) => {
      scene.hidden = i !== index;
      captions[i].hidden = i !== index;
    });

    const scene = scenes[index];
    const still = motion.matches || !scene.animate;
    toggle.hidden = replay.hidden = still;
    if (still || paused) return;

    function animate(node, frames, timing) {
      const effect = node.animate(frames, { easing: "ease-out", fill: "backwards", ...timing });
      effects.push(effect);
      return effect;
    }
    const box = scene.querySelector(".capture-marquee");
    if (box) {
      const bounds = box.getBoundingClientRect();
      animate(box, [
        { width: "2px", height: "2px", opacity: 0 },
        { opacity: 1, offset: .12 },
        { width: bounds.width + "px", height: bounds.height + "px", opacity: 1 }
      ], { delay: 180, duration: 730 });
    } else {
      animate(scene.querySelector("mark"), [
        { backgroundSize: "0% 100%" }, { backgroundSize: "100% 100%" }
      ], { delay: 150, duration: 640 });
      animate(scene.querySelector(".demo-key"), [
        { opacity: 0, transform: "scale(.9)" }, { opacity: 1, transform: "none" }
      ], { delay: 820, duration: 180 });
    }
    animate(scene.querySelector(".hud-panel"), [
      { opacity: 0, transform: "translateY(10px)" }, { opacity: 1, transform: "none" }
    ], { delay: 1050, duration: 350 });
    const reveal = [{ opacity: 0 }, { opacity: 1 }];
    animate(scene.querySelector(".hud-status"), reveal, { delay: 1430, duration: 270 });
    const result = animate(scene.querySelector(".hud-out"), reveal, {
      delay: 1500, duration: 340, endDelay: resultHold
    });
    result.finished.then(() => {
      if (effects.includes(result)) show((index + 1) % scenes.length);
    }, () => {});
    updatePlayback();
  }

  hero.querySelector(".demo-controls").hidden = false;
  hero.querySelector(".demo-next").addEventListener("click", () => show((active + 1) % scenes.length));
  replay.addEventListener("click", () => { paused = false; show(active); });
  toggle.addEventListener("click", () => {
    paused = !paused;
    if (!paused && !effects.length) show(active);
    updatePlayback();
  });
  motion.addEventListener("change", () => { show(active); updatePlayback(); });
  document.addEventListener("visibilitychange", updatePlayback);
  show(0);

  if ("IntersectionObserver" in window) {
    const observer = new IntersectionObserver(entries => {
      entries.forEach(entry => {
        if (entry.target === hero) {
          inView = entry.isIntersecting;
          updatePlayback();
        } else if (entry.isIntersecting) {
          observer.unobserve(entry.target);
          if (!motion.matches) entry.target.classList.add("arriving");
        }
      });
    }, { threshold: .12 });
    [hero, ...document.querySelectorAll(".section-title")].forEach(node => observer.observe(node));

    const tools = document.querySelector(".tools");
    const centers = [...tools.querySelectorAll(".feature-stage")].map(stage => {
      const center = document.createElement("span");
      center.className = "tool-center";
      center.setAttribute("aria-hidden", "true");
      stage.append(center);
      return center;
    });
    let bandObserver;
    let viewportHeight;
    function observeMiddleThird() {
      const height = document.documentElement.clientHeight;
      if (height === viewportHeight) return;
      viewportHeight = height;
      bandObserver?.disconnect();
      const inset = height / 3;
      bandObserver = new IntersectionObserver((entries, current) => {
        if (current !== bandObserver) return;
        for (const entry of entries) {
          entry.target.parentElement.classList.toggle("in-band", entry.isIntersecting);
        }
      }, { rootMargin: "-" + inset + "px 0px" });
      centers.forEach(center => bandObserver.observe(center));
    }
    function updateToolVisibility() {
      tools.classList.toggle("demos-visible", !document.hidden);
    }
    for (const box of tools.querySelectorAll(".capture-target")) {
      const crosshair = cursor.cloneNode(true);
      crosshair.setAttribute("class", "demo-crosshair");
      box.append(crosshair);
    }
    const edit = tools.querySelector(".stage-edit .feature-example");
    const comparison = tools.querySelector(".deskew-comparison");
    function measureDemoTargets() {
      const editBounds = edit.getBoundingClientRect();
      for (const [name, selector] of [["word", ".hud-source .edit-change"], ["refresh", ".hud-foot-tools > svg:last-child"]]) {
        const target = edit.querySelector(selector).getBoundingClientRect();
        edit.style.setProperty("--" + name + "-x", (target.left + target.width / 2 - editBounds.left) + "px");
        edit.style.setProperty("--" + name + "-y", (target.top + target.height / 2 - editBounds.top) + "px");
      }
      // The step boxes stay still while the artwork moves inside them.
      const poster = comparison.firstElementChild.getBoundingClientRect();
      const result = comparison.lastElementChild.getBoundingClientRect();
      const selection = comparison.querySelector(".deskew-selection");
      const zoom = Math.min(1.24, (comparison.closest("figure").clientHeight - 28) / poster.height);
      const posterCenter = comparison.getBoundingClientRect().left + comparison.clientWidth / 2;
      const x = posterCenter + (selection.offsetLeft + selection.offsetWidth / 2 - poster.width / 2) * zoom;
      const y = poster.top + poster.height / 2 + (selection.offsetTop + selection.offsetHeight / 2 - poster.height / 2) * zoom;
      comparison.style.setProperty("--poster-zoom", zoom);
      comparison.style.setProperty("--crop-x", (x - result.left - result.width / 2) + "px");
      comparison.style.setProperty("--crop-y", (y - result.top - result.height / 2) + "px");
      // The original 816px selection occupies 816 / 872 of the deskewed image width before rotation.
      comparison.style.setProperty("--crop-scale", zoom * selection.offsetWidth / (result.width * 816 / 872));
    }
    tools.classList.add("demos-ready");
    measureDemoTargets();
    if ("ResizeObserver" in window) {
      const layout = new ResizeObserver(measureDemoTargets);
      [edit, comparison, comparison.closest("figure")].forEach(node => layout.observe(node));
    } else {
      window.addEventListener("resize", measureDemoTargets);
    }
    new MutationObserver(measureDemoTargets).observe(document.documentElement, { attributes: true, attributeFilter: ["data-lang"] });
    document.fonts?.ready.then(measureDemoTargets);
    motion.addEventListener("change", measureDemoTargets);
    observeMiddleThird();
    updateToolVisibility();
    window.addEventListener("resize", observeMiddleThird);
    document.addEventListener("visibilitychange", updateToolVisibility);
  }
})();

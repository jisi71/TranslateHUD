(function () {
  var KEY = "translatehud.lang";

  var film = document.querySelector(".intro-video");
  var resumeAt = 0;

  if (film) {
    film.addEventListener("loadedmetadata", function () {
      if (resumeAt > 0) film.currentTime = Math.min(resumeAt, film.duration);
      resumeAt = 0;
    });
  }

  function switchFilm(lang) {
    if (!film) return;
    var source = film.getAttribute("data-src-" + lang);
    if (!source || source === film.getAttribute("src")) return;

    var playing = !film.paused && !film.ended;
    if (film.readyState > 0) resumeAt = film.currentTime;
    film.preload = resumeAt > 0 ? "metadata" : "none";
    film.poster = film.getAttribute("data-poster-" + lang);
    film.setAttribute("src", source);
    film.load();
    if (playing) film.play().catch(function () {
      // The native controls remain available if the browser blocks playback.
    });
  }

  function readSaved() {
    try {
      var value = localStorage.getItem(KEY);
      if (value === "en" || value === "zh") return value;
    } catch (error) {
      return "zh";
    }
    return "zh";
  }

  function apply(lang) {
    if (lang !== "en" && lang !== "zh") lang = "zh";
    var root = document.documentElement;
    root.setAttribute("data-lang", lang);
    root.lang = lang === "en" ? "en" : "zh-CN";
    try {
      localStorage.setItem(KEY, lang);
    } catch (error) {
      /* private mode */
    }

    document.querySelectorAll("[data-lang-toggle]").forEach(function (button) {
      button.setAttribute("aria-pressed", lang === "en" ? "true" : "false");
    });

    document.querySelectorAll("[data-alt-zh]").forEach(function (node) {
      var text = node.getAttribute(lang === "en" ? "data-alt-en" : "data-alt-zh");
      if (text) node.alt = text;
    });

    document.querySelectorAll("[data-aria-zh]").forEach(function (node) {
      var text = node.getAttribute(lang === "en" ? "data-aria-en" : "data-aria-zh");
      if (text) node.setAttribute("aria-label", text);
    });

    switchFilm(lang);

    var title = document.querySelector("title");
    if (title) {
      var nextTitle = title.getAttribute(lang === "en" ? "data-title-en" : "data-title-zh");
      if (nextTitle) document.title = nextTitle;
    }

    var description = document.querySelector('meta[name="description"]');
    if (description) {
      var nextDescription = description.getAttribute(lang === "en" ? "data-desc-en" : "data-desc-zh");
      if (nextDescription) description.setAttribute("content", nextDescription);
    }
  }

  document.addEventListener("click", function (event) {
    var button = event.target.closest("[data-lang-toggle]");
    if (!button) return;
    var current = document.documentElement.getAttribute("data-lang") === "en" ? "en" : "zh";
    apply(current === "en" ? "zh" : "en");
  });

  apply(readSaved());
})();

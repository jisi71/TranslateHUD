(function () {
  // Placeholder until the notarized 0.4.0 Release URL is published. Swap this line only.
  var DOWNLOAD_URL = "https://github.com/jisi71/TranslateHUD/releases/download/v0.3.1/TranslateHUD-0.3.1-universal.zip";

  var INVITE_STATUS_URL = "https://translatehud-d4gl951eo8bef4702-1445578102.ap-shanghai.app.tcloudbase.com/v1/trial/invite-status";
  var SESSION_KEY = "translatehud.downloaded";

  var statusState = { phase: "idle", remaining: null };

  function remembered() {
    try {
      return sessionStorage.getItem(SESSION_KEY) === "1";
    } catch (error) {
      return false;
    }
  }

  function remember() {
    try {
      sessionStorage.setItem(SESSION_KEY, "1");
    } catch (error) {
      /* private mode */
    }
  }

  function language() {
    return document.documentElement.getAttribute("data-lang") === "en" ? "en" : "zh";
  }

  function readRemaining(data) {
    if (!data || typeof data !== "object") return null;
    var value = data.remaining;
    if (typeof value === "string" && value.trim() !== "") {
      var parsed = Number(value);
      if (Number.isFinite(parsed)) value = parsed;
    }
    if (typeof value === "number" && Number.isFinite(value)) return value;
    if (data.exhausted === true) return 0;
    return null;
  }

  function countText() {
    if (statusState.phase === "loading") return language() === "en" ? "Loading…" : "加载中…";
    if (statusState.phase === "ready") return String(statusState.remaining);
    return "—";
  }

  function renderCount() {
    var text = countText();
    document.querySelectorAll("[data-invite-remaining]").forEach(function (node) {
      node.textContent = text;
    });
  }

  function panelMarkup() {
    return (
      '<div class="invite-panel">' +
      '<p class="invite-line">' +
      '<span class="lang-zh">输入邀请码：translatehud-200 新用户得2元使用额度</span>' +
      '<span class="lang-en">Invite code: translatehud-200 — new users get ¥2 credit</span>' +
      "</p>" +
      '<p class="invite-remaining">' +
      '<span class="lang-zh">剩余可兑换次数：</span>' +
      '<span class="lang-en">Remaining redemptions: </span>' +
      '<span data-invite-remaining>—</span>' +
      "</p>" +
      "</div>"
    );
  }

  function ensurePanels() {
    document.querySelectorAll("[data-download-slot]").forEach(function (slot) {
      if (slot.querySelector(".invite-panel")) return;
      slot.insertAdjacentHTML("beforeend", panelMarkup());
    });
  }

  function loadStatus() {
    if (statusState.phase === "loading" || statusState.phase === "ready") {
      renderCount();
      return;
    }
    statusState.phase = "loading";
    renderCount();
    var controller = typeof AbortController === "function" ? new AbortController() : null;
    var timer = window.setTimeout(function () {
      if (controller) controller.abort();
    }, 8000);
    fetch(INVITE_STATUS_URL, {
      method: "GET",
      credentials: "omit",
      signal: controller ? controller.signal : undefined
    })
      .then(function (response) {
        if (!response.ok) throw new Error("status");
        return response.json();
      })
      .then(function (data) {
        var remaining = readRemaining(data);
        if (remaining === null) throw new Error("remaining");
        statusState.phase = "ready";
        statusState.remaining = remaining;
        renderCount();
      })
      .catch(function () {
        if (statusState.phase === "ready") return;
        statusState.phase = "error";
        statusState.remaining = null;
        renderCount();
      })
      .then(function () {
        window.clearTimeout(timer);
      });
  }

  function openInvite() {
    ensurePanels();
    remember();
    loadStatus();
    window.setTimeout(function () {
      document.querySelectorAll("[data-download-slot]").forEach(function (slot) {
        slot.classList.add("is-invited");
      });
      renderCount();
    }, 0);
  }

  document.querySelectorAll("[data-download]").forEach(function (link) {
    link.setAttribute("href", DOWNLOAD_URL);
  });

  document.addEventListener("click", function (event) {
    var link = event.target.closest("[data-download]");
    if (!link) return;
    link.setAttribute("href", DOWNLOAD_URL);
    openInvite();
  });

  if (window.MutationObserver) {
    new MutationObserver(renderCount).observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-lang"]
    });
  }

  if (remembered()) openInvite();
})();

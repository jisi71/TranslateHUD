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

  function copyButtonMarkup() {
    var label = language() === "en" ? "Copy invite code" : "复制邀请码";
    return (
      '<button type="button" class="invite-copy" data-copy-invite="translatehud-200" aria-label="' + label + '" data-aria-zh="复制邀请码" data-aria-en="Copy invite code">' +
      '<svg class="icon-copy" viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">' +
      '<rect x="5.2" y="5.2" width="8.2" height="8.2" rx="1.4" fill="none" stroke="currentColor" stroke-width="1.5"></rect>' +
      '<path d="M10.6 5.2V3.4A1.4 1.4 0 0 0 9.2 2H3.4A1.4 1.4 0 0 0 2 3.4v5.8A1.4 1.4 0 0 0 3.4 10.6H5.2" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"></path>' +
      "</svg>" +
      '<svg class="icon-check" viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">' +
      '<path d="M3.2 8.3 6.3 11.4 12.8 4.6" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"></path>' +
      "</svg>" +
      "</button>"
    );
  }

  function panelMarkup() {
    return (
      '<div class="invite-panel">' +
      '<div class="invite-code button secondary large">' +
      '<span class="lang-zh">邀请码：translatehud-200</span>' +
      '<span class="lang-en">Invite code: translatehud-200</span>' +
      copyButtonMarkup() +
      "</div>" +
      '<p class="invite-note">' +
      '<span class="lang-zh">新用户输入的2元使用额度 剩余可兑换次数：</span>' +
      '<span class="lang-en">New users enter the code for ¥2 credit. Remaining redemptions: </span>' +
      '<span data-invite-remaining>' + countText() + "</span>" +
      "</p>" +
      "</div>"
    );
  }

  function inviteHosts() {
    return document.querySelectorAll("[data-invite-host]");
  }

  function ensurePanels() {
    inviteHosts().forEach(function (slot) {
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
      inviteHosts().forEach(function (slot) {
        slot.classList.add("is-invited");
      });
      renderCount();
    }, 0);
  }

  function markCopied(button) {
    if (button._copyTimer) window.clearTimeout(button._copyTimer);
    button.classList.add("is-copied");
    var copied = language() === "en" ? "Copied" : "已复制";
    button.setAttribute("aria-label", copied);
    button._copyTimer = window.setTimeout(function () {
      button.classList.remove("is-copied");
      var label = button.getAttribute(language() === "en" ? "data-aria-en" : "data-aria-zh");
      if (label) button.setAttribute("aria-label", label);
    }, 1200);
  }

  function copyCode(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(text);
    }
    return new Promise(function (resolve, reject) {
      var area = document.createElement("textarea");
      area.value = text;
      area.setAttribute("readonly", "");
      area.style.position = "fixed";
      area.style.top = "0";
      area.style.left = "-9999px";
      document.body.appendChild(area);
      area.select();
      try {
        var ok = document.execCommand("copy");
        document.body.removeChild(area);
        if (ok) resolve();
        else reject(new Error("copy"));
      } catch (error) {
        document.body.removeChild(area);
        reject(error);
      }
    });
  }

  document.querySelectorAll("[data-download]").forEach(function (link) {
    link.setAttribute("href", DOWNLOAD_URL);
  });

  document.addEventListener("click", function (event) {
    var copy = event.target.closest("[data-copy-invite]");
    if (copy) {
      event.preventDefault();
      copyCode(copy.getAttribute("data-copy-invite")).then(function () {
        markCopied(copy);
      }, function () {
        /* keep the icon; no alert */
      });
      return;
    }
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

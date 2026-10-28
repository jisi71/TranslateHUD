(function () {
  // v0.4.2 notarized Developer ID DMG for first-time installation.
  // Version 0.4.2, build 12. macOS 14 or later. Universal (Apple silicon and Intel).
  var DOWNLOAD_URL = "https://github.com/jisi71/TranslateHUD/releases/download/v0.4.2/TranslateHUD-0.4.2-universal.dmg";

  var INVITE_STATUS_URL = "https://translatehud-d4gl951eo8bef4702-1445578102.ap-shanghai.app.tcloudbase.com/v1/trial/invite-status";
  var DEFAULT_INVITE_CODE = "translatehud-200";
  var SESSION_KEY = "translatehud.downloaded";

  var statusState = { phase: "idle", remaining: null, exhausted: false, code: DEFAULT_INVITE_CODE };

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

  function readCode(data) {
    if (!data || typeof data.code !== "string") return DEFAULT_INVITE_CODE;
    var code = data.code.trim();
    return code ? code : DEFAULT_INVITE_CODE;
  }

  function inviteCode() {
    return statusState.code || DEFAULT_INVITE_CODE;
  }

  function escapeHtml(text) {
    return String(text).replace(/[&<>"']/g, function (ch) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch];
    });
  }

  function countText(lang) {
    var which = lang || language();
    if (statusState.phase === "loading") return which === "en" ? "Loading…" : "加载中…";
    if (statusState.phase === "ready") return String(statusState.remaining);
    return "—";
  }

  function fillCount(node, lang, exhausted) {
    if (exhausted) {
      node.textContent = lang === "en" ? "No redemptions left" : "次数已用尽";
      return;
    }
    var prefix = lang === "en" ? "Remaining redemptions: " : "剩余可兑换次数：";
    node.textContent = "";
    node.appendChild(document.createTextNode(prefix));
    var value = document.createElement("span");
    value.setAttribute("data-invite-remaining", "");
    value.textContent = countText(lang);
    node.appendChild(value);
  }

  function renderInvite() {
    var code = inviteCode();
    var exhausted = statusState.phase === "ready" && statusState.exhausted === true;
    document.querySelectorAll("[data-invite-code-label]").forEach(function (node) {
      var lang = node.getAttribute("data-invite-code-label");
      node.textContent = lang === "en" ? "Invite code: " + code : "邀请码：" + code;
    });
    document.querySelectorAll("[data-copy-invite]").forEach(function (node) {
      node.setAttribute("data-copy-invite", code);
    });
    document.querySelectorAll(".invite-note-count").forEach(function (node) {
      fillCount(node, node.getAttribute("data-count-lang"), exhausted);
    });
    document.querySelectorAll("[data-invite-feedback]").forEach(function (node) {
      var state = node.getAttribute("data-state");
      node.classList.toggle("is-error", state === "err");
      node.textContent = state ? feedbackText(state) : "";
    });
  }

  function copyButtonMarkup() {
    var label = language() === "en" ? "Copy invite code" : "复制邀请码";
    return (
      '<button type="button" class="invite-copy" data-copy-invite="' + escapeHtml(inviteCode()) + '" aria-label="' + label + '" data-aria-zh="复制邀请码" data-aria-en="Copy invite code">' +
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

  function feedbackText(state) {
    var en = language() === "en";
    if (state === "ok") return en ? "Copied" : "已复制";
    if (state === "err") {
      return en
        ? "Couldn't copy. Select the invite code and copy it manually."
        : "复制失败，请手动选择邀请码复制。";
    }
    return "";
  }

  function noteMarkup() {
    return (
      '<p class="invite-note">' +
      '<span class="lang-zh"><span class="invite-note-lead">新用户输入邀请码获得2元体验额度</span><span class="invite-note-count" data-count-lang="zh">剩余可兑换次数：<span data-invite-remaining>' + countText("zh") + "</span></span></span>" +
      '<span class="lang-en"><span class="invite-note-lead">New users enter the invite code for ¥2 trial credit</span><span class="invite-note-count" data-count-lang="en">Remaining redemptions: <span data-invite-remaining>' + countText("en") + "</span></span></span>" +
      "</p>" +
      '<p class="invite-feedback" data-invite-feedback role="status" aria-live="polite" aria-atomic="true"></p>'
    );
  }

  function codeMarkup(extraClass) {
    var code = escapeHtml(inviteCode());
    return (
      '<div class="invite-code ' + extraClass + '">' +
      '<span class="lang-zh" data-invite-code-label="zh">邀请码：' + code + "</span>" +
      '<span class="lang-en" data-invite-code-label="en">Invite code: ' + code + "</span>" +
      copyButtonMarkup() +
      "</div>"
    );
  }

  function followMarkup(slotId) {
    return (
      '<div class="invite-follow" data-invite-for="' + escapeHtml(slotId) + '">' +
      noteMarkup() +
      '<p class="invite-again"><a data-download href="' + DOWNLOAD_URL + '">' +
      '<span class="lang-zh">重新下载</span><span class="lang-en">Download again</span>' +
      "</a></p></div>"
    );
  }

  function popoverMarkup() {
    var closeLabel = language() === "en" ? "Close" : "关闭";
    return (
      '<div class="invite-popover" role="dialog" hidden>' +
      '<button type="button" class="invite-popover-close" data-invite-close aria-label="' + closeLabel + '" data-aria-zh="关闭" data-aria-en="Close">&times;</button>' +
      '<div class="invite-popover-code">' +
      '<span class="lang-zh" data-invite-code-label="zh">邀请码：' + escapeHtml(inviteCode()) + "</span>" +
      '<span class="lang-en" data-invite-code-label="en">Invite code: ' + escapeHtml(inviteCode()) + "</span>" +
      copyButtonMarkup() +
      "</div>" +
      noteMarkup() +
      "</div>"
    );
  }

  function ensureInline(slot) {
    if (!slot || slot.getAttribute("data-invite") !== "inline") return;
    if (!slot.id) slot.id = "download-inline";
    if (!slot.querySelector(".invite-code")) {
      slot.insertAdjacentHTML("beforeend", codeMarkup("button secondary large"));
    }
    var row = slot.closest(".cta-row, .release-actions");
    if (!row) return;
    if (row.parentElement.querySelector('.invite-follow[data-invite-for="' + slot.id + '"]')) return;
    row.insertAdjacentHTML("afterend", followMarkup(slot.id));
  }

  function revealInline(slot) {
    ensureInline(slot);
    slot.classList.add("is-invited");
  }

  function ensurePopover(slot) {
    if (!slot.querySelector(".invite-popover")) {
      slot.insertAdjacentHTML("beforeend", popoverMarkup());
    }
  }

  function closePopovers() {
    document.querySelectorAll(".download-slot.is-popover-open").forEach(function (slot) {
      slot.classList.remove("is-popover-open");
      var pop = slot.querySelector(".invite-popover");
      if (pop) pop.hidden = true;
    });
  }

  function clampPopover(slot) {
    var pop = slot.querySelector(".invite-popover");
    if (!pop || pop.hidden) return;
    pop.style.right = "0";
    pop.style.left = "auto";
    pop.style.top = "calc(100% + 10px)";
    pop.style.bottom = "auto";
    var rect = pop.getBoundingClientRect();
    var slotRect = slot.getBoundingClientRect();
    if (rect.left < 12) {
      pop.style.right = "auto";
      pop.style.left = (12 - slotRect.left) + "px";
      rect = pop.getBoundingClientRect();
    }
    if (rect.right > window.innerWidth - 12) {
      pop.style.right = "auto";
      pop.style.left = (window.innerWidth - 12 - rect.width - slotRect.left) + "px";
      rect = pop.getBoundingClientRect();
    }
    if (rect.bottom > window.innerHeight - 8 && slotRect.top > rect.height + 16) {
      pop.style.top = "auto";
      pop.style.bottom = "calc(100% + 10px)";
    }
  }

  function openPopover(slot) {
    closePopovers();
    ensurePopover(slot);
    var pop = slot.querySelector(".invite-popover");
    pop.hidden = false;
    slot.classList.add("is-popover-open");
    window.requestAnimationFrame(function () {
      clampPopover(slot);
    });
  }

  function loadStatus() {
    if (statusState.phase === "loading" || statusState.phase === "ready") {
      renderInvite();
      return;
    }
    statusState.phase = "loading";
    renderInvite();
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
        statusState.exhausted = data.exhausted === true;
        statusState.code = readCode(data);
        renderInvite();
      })
      .catch(function () {
        if (statusState.phase === "ready") return;
        statusState.phase = "error";
        statusState.remaining = null;
        statusState.exhausted = false;
        statusState.code = DEFAULT_INVITE_CODE;
        renderInvite();
      })
      .then(function () {
        window.clearTimeout(timer);
      });
  }

  function setFeedback(button, state) {
    var panel = button.closest(".invite-follow, .invite-popover");
    var node = panel && panel.querySelector("[data-invite-feedback]");
    if (!node) return;
    node.setAttribute("data-state", state);
    node.classList.toggle("is-error", state === "err");
    node.textContent = "";
    window.requestAnimationFrame(function () {
      if (node.getAttribute("data-state") !== state) return;
      node.textContent = feedbackText(state);
    });
  }

  function markCopied(button) {
    if (button._copyTimer) window.clearTimeout(button._copyTimer);
    button.classList.add("is-copied");
    button._copyTimer = window.setTimeout(function () {
      button.classList.remove("is-copied");
    }, 1600);
  }

  function fallbackCopy(text) {
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

  function copyCode(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(text).catch(function () {
        return fallbackCopy(text);
      });
    }
    return fallbackCopy(text);
  }

  document.querySelectorAll("[data-download]").forEach(function (link) {
    link.setAttribute("href", DOWNLOAD_URL);
  });

  document.addEventListener("click", function (event) {
    if (event.target.closest("[data-invite-close]")) {
      event.preventDefault();
      closePopovers();
      return;
    }
    var copy = event.target.closest("[data-copy-invite]");
    if (copy) {
      event.preventDefault();
      copyCode(copy.getAttribute("data-copy-invite")).then(function () {
        markCopied(copy);
        setFeedback(copy, "ok");
      }, function () {
        copy.classList.remove("is-copied");
        setFeedback(copy, "err");
      });
      return;
    }
    var link = event.target.closest("[data-download]");
    if (link) {
      link.setAttribute("href", DOWNLOAD_URL);
      remember();
      var slot = link.closest("[data-download-slot]");
      if (!slot) {
        var follow = link.closest(".invite-follow");
        var owner = follow && follow.getAttribute("data-invite-for");
        slot = owner ? document.getElementById(owner) : null;
      }
      if (slot && slot.getAttribute("data-invite") === "inline") {
        closePopovers();
        revealInline(slot);
      } else if (slot) {
        openPopover(slot);
      }
      renderInvite();
      loadStatus();
      return;
    }
    if (!event.target.closest(".invite-popover")) closePopovers();
  });

  document.addEventListener("keydown", function (event) {
    if (event.key === "Escape") closePopovers();
  });

  window.addEventListener("resize", function () {
    document.querySelectorAll(".download-slot.is-popover-open").forEach(clampPopover);
  });

  if (window.MutationObserver) {
    new MutationObserver(renderInvite).observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-lang"]
    });
  }

  if (remembered()) {
    document.querySelectorAll('[data-download-slot][data-invite="inline"]').forEach(revealInline);
    renderInvite();
    loadStatus();
  }
})();

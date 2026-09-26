/* Progressive enhancement, not an application.
 *
 * Every action here is a POST or DELETE to the same JSON API a script would
 * use — the dashboard is a client of the API, not a privileged path into it.
 * That is deliberate: it means the API cannot quietly rot while the UI keeps
 * working, because the UI breaks first.
 *
 * Cookie auth carries the token, so no header is needed here.
 */

const flash = (msg, bad = false) => {
  const el = document.getElementById("flash");
  el.textContent = msg;
  el.classList.toggle("bad", bad);
  el.classList.add("show");
  clearTimeout(flash._t);
  flash._t = setTimeout(() => el.classList.remove("show"), bad ? 6000 : 3000);
};

async function call(method, url, body) {
  const opts = { method, headers: {} };
  if (body !== undefined) {
    opts.headers["Content-Type"] = "application/json";
    opts.body = JSON.stringify(body);
  }
  const res = await fetch(url, opts);
  let data = {};
  try { data = await res.json(); } catch { /* 204, or an HTML error page */ }
  if (!res.ok || data.ok === false) {
    throw new Error(data.detail || `${res.status} ${res.statusText}`);
  }
  return data;
}

/* An action either succeeds and the page no longer reflects reality, or it
 * fails and the page is still right. So: reload on success, restore on
 * failure. No optimistic UI — with file moves, a wrong guess about what
 * happened is worse than a reload. */
async function act(btn, method, url, body, okMsg) {
  const card = btn.closest(".card, .group, .tile");
  const label = btn.textContent;
  btn.disabled = true;
  card && card.classList.add("spin");
  try {
    const data = await call(method, url, body);
    flash(okMsg || data.detail || "done");
    setTimeout(() => location.reload(), 500);
  } catch (err) {
    flash(err.message, true);
    btn.disabled = false;
    btn.textContent = label;
    card && card.classList.remove("spin");
  }
}

document.addEventListener("click", (ev) => {
  const btn = ev.target.closest("[data-action]");
  if (!btn) return;
  ev.preventDefault();

  const a = btn.dataset;
  const name = encodeURIComponent(a.name || "");

  switch (a.action) {
    /* One button, two endpoints. With an identifier it re-imports against
     * exactly that release (/resolve); blank, it hands the entry back to the
     * inbox for the normal two-pass import (/retry). */
    case "retry": {
      const input = document.getElementById(`id-${a.idx}`);
      const identifier = ((input && input.value) || "").trim();
      if (identifier) {
        return act(btn, "POST", `/quarantine/${name}/resolve`, { identifier },
                   "re-imported");
      }
      return act(btn, "POST", `/quarantine/${name}/retry`, undefined,
                 "moved back to the inbox");
    }

    case "drop":
      if (!confirm(`Delete "${a.name}" permanently?\n\nThe files are removed from disk. This cannot be undone.`)) return;
      return act(btn, "DELETE", `/quarantine/${name}`, undefined, "deleted");

    case "merge": {
      const entries = JSON.parse(a.entries);
      return act(btn, "POST", "/quarantine/merge",
                 { entries, album: a.album || null },
                 "merged and handed back to the inbox");
    }

    case "add-open": {
      const form = document.getElementById("add-form");
      form.hidden = !form.hidden;
      btn.setAttribute("aria-expanded", String(!form.hidden));
      if (!form.hidden) document.getElementById("magnet").focus();
      return;
    }

    case "add": {
      const input = document.getElementById("magnet");
      const magnet = (input.value || "").trim();
      if (!magnet) { input.focus(); return flash("paste a magnet link", true); }
      return act(btn, "POST", "/torrents", { magnet });
    }

    case "move":
      return act(btn, "POST", `/torrents/${name}/move`);

    case "resume":
      return act(btn, "POST", `/torrents/${name}/resume`);

    case "cancel":
      if (!confirm(`Cancel "${a.label}" and delete what it downloaded?`)) return;
      return act(btn, "DELETE", `/torrents/${name}`);

    case "nudge":
      return act(btn, "POST", "/inbox/nudge");

    case "approve":
      return act(btn, "POST", `/fetched/${name}/approve`, undefined,
                 "approved — the inbox will import it");

    case "reject":
      if (!confirm(`Reject "${a.name}"?\n\nThe download is deleted from disk.`)) return;
      return act(btn, "POST", `/fetched/${name}/reject`, undefined, "rejected");
  }
});

/* Live progress on the Fetch page. Re-renders #torrents from the server
 * rather than formatting numbers here, so there is one template for a card,
 * not two. Stops by itself once nothing is downloading. */
async function pollTorrents() {
  const list = document.getElementById("torrents");
  if (!list || !list.querySelector('[data-active="1"]')) return;
  try {
    const res = await fetch(location.pathname, { cache: "no-store" });
    const doc = new DOMParser().parseFromString(await res.text(), "text/html");
    const fresh = doc.getElementById("torrents");
    // Never swap a card out from under a click in progress.
    if (fresh && !list.querySelector(".spin")) list.replaceWith(fresh);
  } catch { /* offline for a moment; try again next tick */ }
  setTimeout(pollTorrents, 3000);
}
setTimeout(pollTorrents, 3000);

/* Enter in an ID field is the same as pressing Retry next to it; in the
 * magnet field, the same as pressing Fetch. */
document.addEventListener("keydown", (ev) => {
  if (ev.key !== "Enter") return;
  if (ev.target.id === "magnet") {
    ev.preventDefault();
    return document.querySelector('[data-action="add"]')?.click();
  }
  const input = ev.target.closest("input[data-resolve-for]");
  if (!input) return;
  ev.preventDefault();
  document.querySelector(
    `[data-action="retry"][data-idx="${input.dataset.resolveFor}"]`
  )?.click();
});

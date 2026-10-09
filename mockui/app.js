"use strict";

// Mock dashboard: single page, no dependencies and no build step.
// The server (server.py) returns the whole state at every call, so there is
// nothing to keep in sync by hand: every response replaces `state`.

let state = { enabled: false, mocks: [], hits: {}, methods: [], no_body_status: [] };
let editing = null;   // id of the mock being edited, or "new"
let pendingFile = null;  // file chosen but not yet uploaded (saved first)
let copied = null;    // new mock prefilled from a real request, or null
let copiedNote = "";  // what could not be copied from it (binary content, ...)
let flows = null;     // requests offered by the picker, null = not read yet

const $ = (id) => document.getElementById(id);

// --- small DOM helper ------------------------------------------------------

function el(tag, props = {}, children = []) {
  const node = Object.assign(document.createElement(tag), props);
  for (const child of [].concat(children)) {
    if (child) node.append(child);
  }
  return node;
}

function showError(message) {
  const box = $("error");
  box.textContent = message;
  box.hidden = false;
  clearTimeout(showError.timer);
  showError.timer = setTimeout(() => { box.hidden = true; }, 5000);
}

// --- server ----------------------------------------------------------------

async function api(path, options = {}) {
  if (options.json !== undefined) {
    options.body = JSON.stringify(options.json);
    options.headers = { "Content-Type": "application/json" };
    delete options.json;
  }
  const response = await fetch(path, options);
  if (!response.ok) {
    showError(`${response.status} ${response.statusText}`);
    throw new Error(response.statusText);
  }
  state = await response.json();
  render();
  return state;
}

// Requests of the history: unlike the mocks, these are not the state of the
// dashboard, so they do not go through api()
async function fetchJson(path) {
  const response = await fetch(path);
  if (!response.ok) {
    showError(`${response.status} ${response.statusText}`);
    throw new Error(response.statusText);
  }
  return response.json();
}

// --- global switch ---------------------------------------------------------

function renderSwitch() {
  const button = $("switch-btn");
  button.setAttribute("aria-pressed", String(state.enabled));
  $("switch-label").textContent = state.enabled ? "Mocks on" : "Mocks off";
  $("switch-note").textContent = state.enabled
    ? "Matching requests do not reach the server."
    : "Traffic passes through.";
}

$("switch-btn").onclick = () =>
  api("/api/enabled", { method: "POST", json: { enabled: !state.enabled } });

// --- mock list -------------------------------------------------------------

function matchSummary(mock) {
  const methods = mock.methods.length ? mock.methods.join(" ") : "ANY";
  const query = mock.query.map((p) => `${p.key}=${p.value}`).join("&");
  return `${methods}  ${mock.host || "*"}${mock.path || "/*"}${query ? "?" + query : ""}`;
}

function mockCard(mock, index) {
  const hits = state.hits[mock.id] || {};
  const enabled = el("input", { type: "checkbox", checked: mock.enabled });
  enabled.onchange = () => save({ ...mock, enabled: enabled.checked }, mock.id);

  const button = (text, title, onclick, extra = "icon") => {
    const b = el("button", { type: "button", textContent: text, title, className: extra });
    b.onclick = onclick;
    return b;
  };

  const card = el("div", {
    className: `mock${mock.enabled ? "" : " disabled"}${editing === mock.id ? " selected" : ""}`,
  }, [
    el("div", { className: "mock-top" }, [
      el("label", { className: "check", title: "Enable or disable this mock" }, [enabled]),
      el("span", { className: "mock-title", textContent: mock.name }),
      el("span", { className: `badge status-${String(mock.status)[0]}`, textContent: mock.status }),
      hits.count
        ? el("span", { className: "badge hits", textContent: `${hits.count}×`, title: `Last: ${hits.last || "-"}` })
        : null,
    ]),
    el("div", { className: "mock-match", textContent: matchSummary(mock) }),
    el("div", { className: "mock-actions" }, [
      button("↑", "Move up", () => move(mock.id, "up")),
      button("↓", "Move down", () => move(mock.id, "down")),
      button("Duplicate", "", () => duplicate(mock), ""),
      button("Delete", "", () => remove(mock), "danger"),
    ]),
  ]);

  card.querySelectorAll(".mock-actions button")[0].disabled = index === 0;
  card.querySelectorAll(".mock-actions button")[1].disabled = index === state.mocks.length - 1;

  // The card is the way into the editor: clicking it selects the mock. The
  // switch and the action buttons keep their own behaviour.
  card.onclick = (event) => {
    if (!event.target.closest(".mock-actions, .check")) openEditor(mock.id);
  };
  return card;
}

function renderList() {
  const list = $("list");
  list.textContent = "";
  state.mocks.forEach((mock, i) => list.append(mockCard(mock, i)));
  const active = state.mocks.filter((m) => m.enabled).length;
  $("count").textContent = state.mocks.length ? `— ${active} enabled out of ${state.mocks.length}` : "";
}

// --- actions ---------------------------------------------------------------

const move = (id, direction) =>
  api(`/api/mocks/${id}/move`, { method: "POST", json: { direction } });

const duplicate = (mock) =>
  api("/api/mocks", { method: "POST", json: { ...mock, name: `${mock.name} (copy)`, body_mode: "text" } });

async function remove(mock) {
  if (!confirm(`Delete the mock “${mock.name}”?`)) return;
  if (editing === mock.id) closeEditor();
  await api(`/api/mocks/${mock.id}`, { method: "DELETE" });
}

async function save(mock, id) {
  const path = id ? `/api/mocks/${id}` : "/api/mocks";
  await api(path, { method: id ? "PUT" : "POST", json: mock });
  return id || state.mocks[state.mocks.length - 1].id;
}

// --- editor ----------------------------------------------------------------

const EMPTY = {
  name: "", enabled: true, methods: [], host: "", path: "", query: [],
  status: 200, content_type: "", headers: [], body_mode: "text", body: "",
  body_file: "", body_filename: "",
};

function openEditor(id, prefill = null, note = "") {
  editing = id;
  pendingFile = null;
  // Missing fields (a mock copied from a request has no body_file) come from
  // EMPTY: renderEditor() reads them all
  copied = prefill ? { ...EMPTY, ...prefill } : null;
  copiedNote = prefill ? note : "";
  render();
}

function closeEditor() {
  editing = null;
  pendingFile = null;
  copied = null;
  copiedNote = "";
  render();
}

$("new-btn").onclick = () => openEditor("new");

function pairRows(pairs, keyPlaceholder, valuePlaceholder) {
  const container = el("div", { className: "pairs" });

  const addRow = (pair = { key: "", value: "" }) => {
    const key = el("input", { type: "text", value: pair.key, placeholder: keyPlaceholder });
    const value = el("input", { type: "text", value: pair.value, placeholder: valuePlaceholder });
    const del = el("button", { type: "button", textContent: "×", className: "icon", title: "Remove" });
    const row = el("div", { className: "pair" }, [key, value, del]);
    del.onclick = () => row.remove();
    container.append(row);
  };

  pairs.forEach(addRow);
  const add = el("button", {
    type: "button", textContent: "+", className: "icon", title: "Add row", ariaLabel: "Add row",
  });
  add.onclick = () => addRow();
  return [container, add];
}

function renderEditor() {
  const pane = $("editor-pane");
  pane.hidden = editing === null;
  if (editing === null) return;

  const draft = editing === "new"
    ? copied || { ...EMPTY }
    : state.mocks.find((m) => m.id === editing);
  if (!draft) return closeEditor();

  // --- fields
  const name = el("input", { type: "text", value: draft.name, placeholder: "Mock name" });

  const methodBoxes = state.methods.map((method) => {
    const input = el("input", { type: "checkbox", value: method, checked: draft.methods.includes(method) });
    return el("label", {}, [input, document.createTextNode(method)]);
  });

  const host = el("input", { type: "text", value: draft.host, placeholder: "api.example.com or *.example.com" });
  const path = el("input", { type: "text", value: draft.path, placeholder: "/v1/users or /v1/*" });
  const [queryRows, queryAdd] = pairRows(draft.query, "parameter", "value");

  const status = el("input", { type: "number", value: draft.status, min: 100, max: 599 });
  const contentType = el("input", { type: "text", value: draft.content_type, placeholder: "application/json" });
  const [headerRows, headerAdd] = pairRows(draft.headers, "header", "value");

  const modeText = el("input", { type: "radio", name: "body_mode", value: "text", checked: draft.body_mode !== "file" });
  const modeFile = el("input", { type: "radio", name: "body_mode", value: "file", checked: draft.body_mode === "file" });
  const body = el("textarea", { value: draft.body, placeholder: "Response content" });
  const file = el("input", { type: "file" });
  const fileInfo = el("p", { className: "note" });

  const bodyBox = el("fieldset", {}, [
    el("legend", { textContent: "Content" }),
    el("div", { className: "radios" }, [
      el("label", {}, [modeText, document.createTextNode("Text")]),
      el("label", {}, [modeFile, document.createTextNode("File")]),
    ]),
    body,
    file,
    fileInfo,
  ]);

  // --- reactive bits
  const refreshBody = () => {
    const code = Number(status.value);
    const noBody = state.no_body_status.includes(code) || code < 200;
    bodyBox.disabled = noBody;
    bodyBox.title = noBody ? `Status ${code} carries no content` : "";
    body.hidden = modeFile.checked;
    file.hidden = !modeFile.checked;
    fileInfo.hidden = !modeFile.checked;
    if (pendingFile) {
      fileInfo.textContent = `To upload on save: ${pendingFile.name}`;
    } else if (draft.body_filename) {
      fileInfo.textContent = `Current file: ${draft.body_filename}`;
    } else {
      fileInfo.textContent = "No file: choose one and save.";
    }
  };
  status.oninput = refreshBody;
  modeText.onchange = modeFile.onchange = refreshBody;
  file.onchange = () => {
    pendingFile = file.files[0] || null;
    if (pendingFile && !contentType.value) {
      // left empty, the server guesses the type from the extension
      contentType.placeholder = "guessed from the file extension";
    }
    refreshBody();
  };

  // --- save / cancel
  const saveBtn = el("button", {
    type: "button", textContent: "✓", className: "primary", title: "Save", ariaLabel: "Save",
  });
  const cancelBtn = el("button", {
    type: "button", textContent: "✕", title: "Cancel", ariaLabel: "Cancel",
  });
  cancelBtn.onclick = closeEditor;

  saveBtn.onclick = async () => {
    const mock = {
      name: name.value,
      methods: methodBoxes.filter((l) => l.firstChild.checked).map((l) => l.firstChild.value),
      host: host.value,
      path: path.value,
      query: [...queryRows.children].map((r) => ({ key: r.children[0].value, value: r.children[1].value })),
      status: Number(status.value),
      content_type: contentType.value,
      headers: [...headerRows.children].map((r) => ({ key: r.children[0].value, value: r.children[1].value })),
      body_mode: modeFile.checked ? "file" : "text",
      body: body.value,
    };
    saveBtn.disabled = true;
    try {
      const id = await save(mock, editing === "new" ? null : editing);
      if (pendingFile) {
        const form = new FormData();
        form.append("file", pendingFile);
        await api(`/api/mocks/${id}/body`, { method: "POST", body: form });
        pendingFile = null;
      }
      openEditor(id);
    } finally {
      saveBtn.disabled = false;
    }
  };

  const field = (labelText, control, note) =>
    el("div", { className: "field" }, [
      el("label", { textContent: labelText }),
      control,
      note ? el("p", { className: "note", textContent: note }) : null,
    ]);

  const editor = el("div", {}, [
    el("div", { className: "pane-head" }, [
      el("h2", {
        textContent: editing !== "new" ? "Edit mock"
          : copied ? "New mock from a request" : "New mock",
      }),
      el("div", { className: "form-actions" }, [saveBtn, cancelBtn]),
    ]),
    copiedNote ? el("p", { className: "note warn", textContent: copiedNote }) : null,

    field("Name", name),

    el("h3", { textContent: "Match" }),
    field("Methods", el("div", { className: "methods" }, methodBoxes), "None selected = any method."),
    el("div", { className: "row" }, [
      field("Host", host),
      field("Path", path),
    ]),
    el("p", { className: "note", textContent: "Host and path accept a trailing * as a wildcard (*.example.com, /v1/*); the host also a leading *. Empty = any." }),
    field("Query string", el("div", { className: "pair-field" }, [queryRows, queryAdd]),
      "Every pair listed must be present; other parameters are ignored."),

    el("h3", { textContent: "Response" }),
    el("div", { className: "row" }, [
      field("Status code", status),
      field("Content-Type", contentType),
    ]),
    field("Extra headers", el("div", { className: "pair-field" }, [headerRows, headerAdd])),
    bodyBox,
  ]);

  pane.textContent = "";
  pane.append(editor);
  refreshBody();
}

// --- picker: a new mock copied from a real request -------------------------
//
// The requests come from mitmproxy's history, which only the addon can see:
// the dashboard asks it through /api/history (see server.py). Choosing one
// fills the form of a new mock, which is saved like any other.

const sizeText = (bytes) =>
  bytes === null ? "" : bytes < 1024 ? `${bytes} B` : `${Math.round(bytes / 1024)} KB`;

function flowRow(flow) {
  const about = [flow.content_type, sizeText(flow.size)].filter(Boolean).join("  ·  ");
  const row = el("div", { className: "flow" }, [
    el("div", { className: "flow-top" }, [
      el("span", { className: "badge", textContent: flow.method }),
      el("span", {
        className: `badge status-${String(flow.status)[0]}`,
        textContent: flow.status === null ? "—" : flow.status,
        title: flow.status === null ? "No response" : "",
      }),
      el("span", { className: "flow-host", textContent: flow.host }),
      el("span", { className: "muted", textContent: flow.time }),
    ]),
    el("div", { className: "flow-path", textContent: flow.path }),
    about ? el("div", { className: "flow-note", textContent: about }) : null,
  ]);
  row.onclick = () => pick(flow.id);
  return row;
}

function renderPicker() {
  const list = $("picker-list");
  list.textContent = "";
  if (flows === null) {
    $("picker-count").textContent = "";
    list.append(el("p", { className: "note", textContent: "Reading mitmproxy's history…" }));
    return;
  }
  const needle = $("picker-filter").value.trim().toLowerCase();
  const shown = flows.filter((f) =>
    `${f.method} ${f.host}${f.path}`.toLowerCase().includes(needle));
  $("picker-count").textContent = flows.length ? `— ${shown.length} of ${flows.length}` : "";
  if (!shown.length) {
    list.append(el("p", {
      className: "note",
      textContent: flows.length
        ? "No request matches the filter."
        : "Nothing in the history: the traffic has to pass through mitmproxy first.",
    }));
    return;
  }
  shown.forEach((flow) => list.append(flowRow(flow)));
}

async function loadHistory() {
  flows = null;
  renderPicker();
  try {
    flows = (await fetchJson("/api/history")).flows;
  } catch {
    flows = [];
  }
  renderPicker();
}

function openPicker() {
  $("picker").hidden = false;
  $("picker-filter").value = "";
  $("picker-filter").focus();
  loadHistory();
}

const closePicker = () => { $("picker").hidden = true; };

async function pick(id) {
  let answer;
  try {
    answer = await fetchJson(`/api/history/${id}`);
  } catch {
    return;  // gone from the history, or mitmproxy not answering
  }
  closePicker();
  openEditor("new", answer.mock, answer.note);
  if (!answer.download) return;
  // Content left out of the form (binary, or too big). alert() blocks until
  // it is closed: the download starts right after, as the message says.
  alert(
    `${answer.note}.\n\n` +
    "The original response is downloaded as a file: to use it as the content " +
    'of the mock, choose "File" under Content and upload it.'
  );
  downloadBody(id);
}

// The file does not go through <a href>: this way an error (the flow gone
// from the history in the meantime, mitmproxy restarted) is shown like the
// others instead of becoming a failed download.
async function downloadBody(id) {
  let response;
  try {
    response = await fetch(`/api/history/${id}/body`);
  } catch {
    return showError("Download of the response failed");
  }
  if (!response.ok) return showError(`${response.status} ${response.statusText}`);

  const disposition = response.headers.get("content-disposition") || "";
  const link = el("a", {
    href: URL.createObjectURL(await response.blob()),
    download: (disposition.match(/filename="([^"]*)"/) || [])[1] || "response",
  });
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(link.href), 60000);
}

$("from-btn").onclick = openPicker;
$("picker-close").onclick = closePicker;
$("picker-refresh").onclick = loadHistory;
$("picker-filter").oninput = renderPicker;
$("picker").onclick = (event) => { if (event.target.id === "picker") closePicker(); };
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && !$("picker").hidden) closePicker();
});

// --- loop ------------------------------------------------------------------

function render() {
  renderSwitch();
  renderList();
  renderEditor();
}

// Re-reads the state to keep the hit counters and any change made by hand to
// mocks.json up to date. While editing, only the switch and the list are
// refreshed: renderEditor() rebuilds the form from the server state and would
// throw away what is being typed.
async function refresh() {
  const response = await fetch("/api/mocks");
  if (!response.ok) return;
  state = await response.json();
  renderSwitch();
  renderList();
  if (editing === null) renderEditor();
}

api("/api/mocks").catch(() => showError("Dashboard unreachable"));
setInterval(() => refresh().catch(() => {}), 2000);

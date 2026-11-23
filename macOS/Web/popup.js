"use strict";
const el = (id) => document.getElementById(id);
const send = (action, data = {}) => window.webkit.messageHandlers.betterIcon.postMessage({ action, ...data });
// Each BetterIcon app icon, in menu order. The app takes its colors from the chosen one.
const styles = [
  ["clay", "Clay"], ["copper", "Copper"], ["mauve", "Mauve"], ["ochre", "Ochre"], ["sage", "Sage"],
  ["slate", "Slate"], ["stone", "Stone"], ["teal", "Teal"], ["grayscale", "Grayscale"], ["contrast", "High contrast"],
];
const appearanceOrder = ["Dark", "Light", "System"];
const selected = { apps: "", preview: "" };
let model,
  page = "launcher",
  prefix = "",
  editorFiles = {},
  working = false,
  viewGeneration = 0;
const text = (id, value) => {
  el(id).textContent = value;
};
const activeDialog = () => document.querySelector("dialog[open]");
function make(tag, content) {
  const node = document.createElement(tag);
  if (content !== undefined) node.textContent = content;
  return node;
}
function tab(name, focus = true) {
  closePackPicker();
  page = name;
  document.body.dataset.page = name;
  for (const id of ["launcher", "manage"]) {
    el(id).hidden = id !== name;
    el(id + "Tab").setAttribute("aria-selected", String(id === name));
  }
  closeMenu();
  if (focus) (name === "launcher" ? el("apps") : el("packs")).focus();
}
function requestTab(name) {
  if (name !== page) send("tab", { name });
}
function reset(pageName) {
  if (activeDialog()) return;
  prefix = "";
  selected.apps = "";
  selected.preview = "";
  tab(pageName || "launcher");
  if (model) grids();
}
function iconURL(base, size) {
  return base + "?size=" + Math.min(4096, Math.round(size * window.devicePixelRatio));
}
function packActions(group = "apps") {
  const files = group === "files",
    p = files ? model.filePack : model.pack;
  const items = [
    ["Customize…", () => send("editor", { mode: "customize", group }), !p.default],
    ["Edit pack…", () => send("editor", { mode: "edit", group }), p.personal],
    ["Export ZIP…", () => send("export", { group }), p.personal],
    [files ? "Remove file pack" : "Remove app pack", () => send("remove", { group }), !p.default],
  ];
  if (!files) items.push(["Restore built-in packs", () => send("unhide"), true]);
  return items;
}
function closeMenu() {
  el("menu").hidden = true;
}
function menu(items, x, y, above = false, right = false) {
  if (working) return;
  const node = el("menu");
  node.replaceChildren();
  node.hidden = false;
  for (const [label, action, enabled = true, icon, checked] of items) {
    const b = make("button");
    b.type = "button";
    b.setAttribute("role", "menuitem");
    if (icon) {
      const img = make("img");
      img.src = icon;
      img.alt = "";
      b.append(img);
    }
    b.append(document.createTextNode(label));
    b.disabled = !enabled;
    if (checked) b.className = "chosen";
    b.onclick = () => {
      closeMenu();
      action();
    };
    node.append(b);
  }
  node.style.maxHeight = (above ? Math.max(95, y - 12) : innerHeight - 24) + "px";
  const w = node.offsetWidth,
    h = node.offsetHeight;
  node.style.left = Math.max(9, Math.min(right ? x - w : x, innerWidth - w - 9)) + "px";
  node.style.top = Math.max(8, Math.min(above ? y - h : y, innerHeight - h - 9)) + "px";
  (node.querySelector("button.chosen") || node.querySelector("button:enabled"))?.focus({
    preventScroll: true,
  });
}
function atButton(id, items, above = false) {
  const r = el(id).getBoundingClientRect();
  menu(items, above ? r.right : r.left, above ? r.top - 3 : r.bottom + 2, above, above);
}
function colorMenu() {
  const p = model.prefs,
    resolved = model.dark ? "dark" : "light";
  const items = [
    [
      "Match app theme",
      () => send("brand", { color: p.color, variant: "auto" }),
      true,
      model.brands[p.color + "_" + resolved],
      p.variant === "auto",
    ],
  ];
  for (const [color, name] of styles)
    for (const variant of ["dark", "light"]) {
      items.push([
        name + (variant === "dark" ? " Dark" : " Light"),
        () => send("brand", { color, variant }),
        true,
        model.brands[color + "_" + variant],
        p.color === color && p.variant === variant,
      ]);
    }
  atButton("brand", items, true);
}
function tileMenu(item, x, y) {
  menu(
    [
      ["Choose icon…", () => send("chooseIcon", { craft: item.craft })],
      ["Restore ArtCraft default", () => send("review", { restore: true, only: item.craft })],
    ],
    x,
    y,
  );
}
let hoveredApp = null;
function highlightHoveredApp(tile) {
  if (hoveredApp === tile) return;
  hoveredApp?.classList.remove("hovered");
  hoveredApp = tile;
  tile?.classList.add("hovered");
  el("apps").classList.toggle("pointer", Boolean(tile));
}
// A subtle sign that a click landed: the artwork is drawn smaller and darker while the button is held.
let pressedApp = null;
function pressApp(tile) {
  if (pressedApp === tile) return;
  pressedApp?.classList.remove("pressed");
  pressedApp = tile;
  tile?.classList.add("pressed");
}
el("apps").onpointerdown = e => pressApp(working || e.button !== 0 || e.ctrlKey ? null : e.target.closest(".tile"));
el("apps").onpointermove = e => {
  const tile = working ? null : e.target.closest(".tile");
  if (pressedApp && tile !== pressedApp) pressApp(null);
  highlightHoveredApp(tile);
};
el("apps").onpointerleave = () => {
  pressApp(null);
  highlightHoveredApp(null);
};
for (const released of ["pointerup", "pointercancel", "blur"]) window.addEventListener(released, () => pressApp(null));
function grid(id, items) {
  const area = el(id),
    previous = area.scrollTop;
  if (id === "apps") {
    highlightHoveredApp(null);
    pressApp(null);
  }
  const nodes = items.map((item) => {
    const b = make("button");
    b.className = "tile";
    b.type = "button";
    b.tabIndex = -1;
    b.dataset.key = item.id;
    b.dataset.craft = item.craft;
    b.title = item.hint || item.name;
    b.setAttribute("role", "option");
    b.setAttribute("aria-label", item.name);
    b.setAttribute("aria-selected", String(item.id === selected[id]));
    const img = make("img");
    img.alt = "";
    img.draggable = false;
    img.src = iconURL(item.image, model.prefs.size);
    b.append(img, make("span", item.name));
    const select = () => {
      if (working) return;
      selected[id] = item.id;
      for (const sibling of area.children) sibling.setAttribute("aria-selected", String(sibling === b));
      area.focus({ preventScroll: true });
    };
    b.onclick = id === "apps" ? e => {
      if (working || e.button !== 0 || e.ctrlKey) return;
      select();
      if (e.detail <= 1) send("launch", { id: item.id });
    } : select;
    b.oncontextmenu = (e) => {
      e.preventDefault();
      select();
      tileMenu(item, e.clientX, e.clientY);
    };
    return b;
  });
  area.replaceChildren(...nodes);
  area.scrollTop = previous;
}
function filtered() {
  return model.apps.filter((app) => app.name.toLowerCase().startsWith(prefix.toLowerCase()));
}
// The file type pack's artwork, beside the app pack's. It is a preview only.
function fileTiles() {
  const area = el("filePreview");
  const tiles = (model.filePreview || []).map((file) => {
    const tile = make("div");
    tile.className = "tile";
    tile.setAttribute("role", "listitem");
    tile.title = file.hint || file.name;
    const img = make("img");
    img.alt = "";
    img.draggable = false;
    img.src = iconURL(file.image, model.prefs.size);
    tile.append(img, make("span", file.name));
    return tile;
  });
  area.replaceChildren(...tiles);
  area.hidden = !tiles.length;
}
// The colors of the chosen BetterIcon app icon.
function applyTheme(theme) {
  const css = document.documentElement.style;
  for (const [name, value] of Object.entries(theme || {}))
    css.setProperty("--" + name.replace(/[A-Z]/g, (letter) => "-" + letter.toLowerCase()), value);
}
function grids() {
  const visible = filtered();
  grid("apps", visible);
  grid("preview", model.preview);
  el("empty").hidden = visible.length !== 0;
  text(
    "empty",
    prefix
      ? "No apps match ‘" + prefix + "’. Backspace edits the filter. Escape clears it."
      : model.emptyMessage || "No ArtCraft apps found. Right-click the menu bar icon to refresh or choose an apps folder.",
  );
}
function size(value) {
  const number = Math.max(24, Math.min(model.maxSize, Math.round(Number(value) || model.prefs.size)));
  model.prefs.size = number;
  el("slider").value = number;
  el("exact").value = number;
  const css = document.documentElement.style,
    show = model.prefs.names;
  el("slider").style.setProperty("--fraction", (100 * (number - 24)) / Math.max(1, model.maxSize - 24) + "%");
  css.setProperty("--size", number + "px");
  css.setProperty("--cell", (show ? Math.max(112, number + 24) : number + 24) + "px");
  css.setProperty("--row", number + 16 + (show ? 34 : 0) + "px");
}
const glyphs = {
  Dark: '<path d="M19 22A10 10 0 0 1 16 2a10.3 10.3 0 1 0 3 20Z"/>',
  Light:
    '<circle cx="12" cy="12" r="4"/><path d="M12 1v4m0 14v4M1 12h4m14 0h4M4 4l3 3m10 10 3 3M4 20l3-3M17 7l3-3"/>',
  System: '<rect x="2" y="4" width="20" height="14" rx="2"/><path d="M8 22h8m-4-4v4"/>',
};
function update(next) {
  const gen = ++viewGeneration;
  model = next;
  const p = model.prefs,
    pack = model.pack,
    files = model.filePack,
    kind = (chosen) => (chosen.personal ? "Personal pack" : "Built-in pack");
  document.documentElement.dataset.dark = String(model.dark);
  applyTheme(model.theme);
  document.body.classList.toggle("iconOnly", !p.names);
  setPackButtons(model);
  packUpdateCount(model.packUpdateCount);
  fileTiles();
  // With the original file icons chosen, the one action is to put them back.
  text("applyFiles", files.default ? "Restore original file icons…" : "Apply file icons…");
  el("applyFiles").classList.toggle("primary", !files.default);
  // On the Mac and Linux a pack can also draw file types outside BetterIcon's list. Its count line then comes as fileSummary.
  el("applyFiles").disabled = !files.default && !model.fileCount && !model.fileSummary;
  el("restoreFiles").hidden = files.default;
  el("removeFiles").disabled = files.default;
  // On the Mac a pack's file icons can cover whole folders, which BetterIcon then keeps up to date.
  const folders = model.fileFolders || [];
  text(
    "fileDetail",
    (files.default
      ? "Original file icons from your installed apps."
      : (model.fileSummary || model.fileCount + (model.fileCount === 1 ? " file type" : " file types")) + " / " + kind(files)) +
      (folders.length ? " · " + folders.length + (folders.length === 1 ? " folder" : " folders") + " kept up to date" : ""),
  );
  el("fileDetail").title = folders.join("\n");
  el("apply").disabled = !pack.default && !model.preview.length;
  text(
    "detail",
    pack.default ? "Original icons for your installed apps." : model.preview.length + " icons / " + kind(pack),
  );
  el("remove").disabled = pack.default;
  el("restore").hidden = pack.default;
  el("names").checked = p.names;
  el("slider").max = model.maxSize;
  size(p.size);
  text("apply", pack.default ? "Restore ArtCraft defaults…" : "Apply icons…");
  text("version", "Better Icon for ArtCraft version " + model.version);
  el("version").href = model.projectURL;
  showShortcut(model.shortcut);
  const variant = p.variant === "auto" ? (model.dark ? "dark" : "light") : p.variant;
  el("brand").firstElementChild.src = model.brands[p.color + "_" + variant];
  el("brand").title = "BetterIcon app icon";
  el("appearance").innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true">' + glyphs[p.theme] + "</svg>";
  const nextTheme = appearanceOrder[(appearanceOrder.indexOf(p.theme) + 1) % 3];
  el("appearance").title = p.theme + " appearance. Switch to " + nextTheme + ".";
  loginItem(model.loginItem);
  offer(model.downloadOffer, model.downloads);
  grids();
  if (gen === viewGeneration && model.status) text("status", model.status);
}
// Mac only: whether macOS opens BetterIcon at login. The box shows what macOS says. While macOS waits for the user to
// allow it, a note under the tabs says where, in both tabs.
function loginItem(login) {
  el("loginRow").hidden = !login;
  el("loginNotice").hidden = !login || !login.waiting;
  document.body.classList.toggle("hasLoginNote", Boolean(login && login.waiting));
  if (!login) return;
  const pane = login.pane || "System Settings > General > Login Items";
  el("openAtLogin").checked = login.on;
  el("loginRow").title = login.waiting ? "Waiting for you to allow BetterIcon in " + pane + "." : "";
  text("loginNoticeText", "BetterIcon opens at login once you allow it in " + pane + ".");
  el("loginNoticeText").title = el("loginNoticeText").textContent;
}
function megabytes(group) {
  const mb = group.bytes / 1e6,
    size = (mb < 10 ? mb.toFixed(1) : String(Math.round(mb))) + " MB";
  return group.known ? size : group.bytes ? "at least " + size : "size unknown";
}
// Mac only: a new installation offers once to download every app icon pack and every file type icon pack.
const offerGroups = [
  ["apps", "offerApps", "All app icon packs"],
  ["files", "offerFiles", "All file type icon packs"],
];
function offer(next, downloads) {
  const shown = Boolean(next || downloads);
  el("offer").hidden = !shown;
  document.body.classList.toggle("hasOffer", shown);
  // While the chosen packs download, and afterwards until it is closed, the offer shows how the downloads go.
  el("offerAsk").hidden = Boolean(downloads) || !next;
  el("offerProgress").hidden = !downloads;
  if (downloads) {
    text("offerProgressText", downloads.line);
    el("offerProgressText").title = downloads.line;
    el("offerBar").hidden = downloads.done;
    el("offerClose").hidden = !downloads.done;
  }
  if (!next || downloads) return;
  for (const [key, box, noun] of offerGroups) {
    const group = next[key];
    el(box + "Row").hidden = !group.count;
    if (!group.count) el(box).checked = false;
    text(box + "Text", noun + " · " + group.count + (group.count === 1 ? " pack · " : " packs · ") + megabytes(group));
  }
  offerButton();
}
function offerChoice() {
  const [apps, files] = offerGroups.map(([key, box]) => el(box).checked && !el(box + "Row").hidden);
  return { apps, files };
}
function offerButton() {
  const { apps, files } = offerChoice(),
    next = model.downloadOffer,
    group = apps && files ? next.both : apps ? next.apps : files ? next.files : null;
  el("offerDownload").disabled = !group;
  text("offerDownload", group ? "Download " + megabytes(group) : "Download");
}
function packUpdateCount(count) {
  const button = el("refreshPacks"), hasUpdates = count > 0;
  if (model) model.packUpdateCount = count;
  button.classList.toggle("has-pack-updates", hasUpdates);
  if (hasUpdates) {
    text("packUpdateDescription", `${count} new or updated icon pack${count === 1 ? "" : "s"} available.`);
    button.setAttribute("aria-describedby", "packUpdateDescription");
  } else {
    button.removeAttribute("aria-describedby");
    text("packUpdateDescription", "");
  }
}
function busy(message) {
  working = Boolean(message);
  el("refreshPacks").disabled = working;
  el("busy").hidden = !working;
  el("busy").firstElementChild.textContent = message || "";
  for (const section of [el("launcher"), el("manage"), document.querySelector("nav"), el("offer"), el("loginNotice")])
    section.inert = working;
  for (const dialog of document.querySelectorAll("dialog[open]")) dialog.inert = working;
  if (!working) for (const dialog of document.querySelectorAll("dialog")) dialog.inert = false;
  if (working) { closeMenu(); closePackPicker(); }
}
function editor(info) {
  editorFiles = { ...info.files };
  text("editorTitle", info.edit ? "Edit icon pack" : "Create icon pack");
  el("packName").value = info.name;
  el("author").value = info.author;
  text("editorError", "");
  const rows = info.apps.map((craft) => {
    const row = make("div");
    row.className = "assignment";
    const file = make("span", editorFiles[craft] || "Unassigned");
    file.id = "file-" + craft;
    const choose = make("button", "Choose…");
    choose.type = "button";
    choose.onclick = () => send("pickAssignment", { craft });
    const clear = make("button", "Clear");
    clear.type = "button";
    clear.onclick = () => {
      send("clearAssignment", { craft });
      assignment(craft, "");
    };
    const label = make("span", info.labels?.[craft] || craft);
    label.title = info.hints?.[craft] || label.textContent;
    row.append(label, file, choose, clear);
    return row;
  });
  el("assignments").replaceChildren(...rows);
  el("editor").showModal();
  el("packName").focus();
  el("packName").select();
}
function assignment(craft, name) {
  text("file-" + craft, name || "Unassigned");
}
function showShortcut(shortcut) {
  text("launcherShortcut", "Launcher shortcut · " + shortcut);
}
function hotkey(info) {
  const k = model.prefs.hotkey;
  el("keyEnabled").checked = k.enabled;
  el("modifiers").replaceChildren(
    ...["Control", "Option", "Shift", "Command"].map((label) => {
      const l = make("label");
      l.className = "check";
      const i = make("input");
      i.type = "checkbox";
      i.id = "mod-" + label;
      i.checked = k[label.toLowerCase()];
      l.append(i, document.createTextNode(info.labels?.[label] || label));
      return l;
    }),
  );
  el("key").replaceChildren(...info.keys.map((k) => new Option(k, k)));
  el("key").value = k.key;
  text("keyError", "");
  text("keyStatus", info.status);
  el("hotkey").showModal();
}
function doneDialog(id) {
  if (el(id).open) el(id).close();
}
for (const id of ["editor", "hotkey"]) el(id).addEventListener("close", () => send("dialogClosed", { id }));
// Match AppKit's whole-point divider using the tab bar's measured width.
new ResizeObserver(([bar]) => {
  el("launcherTab").style.flexBasis = Math.floor(bar.contentRect.width / 2) + "px";
}).observe(el("launcherTab").parentElement);
el("launcherTab").onclick = () => requestTab("launcher");
el("manageTab").onclick = () => requestTab("manage");
el("launcherShortcut").onclick = () => send("changeHotkey");
el("packs").onclick = () => openPackPicker("apps");
el("refreshPacks").onclick = () => send("refreshPacks");
el("filePacks").onclick = () => openPackPicker("files");
el("packs").onchange = () => send("select", { id: el("packs").value, group: "apps" });
el("applyFiles").onclick = () => send("reviewFiles", { restore: model.filePack.default });
el("restoreFiles").onclick = () => send("reviewFiles", { restore: true });
el("packs").oncontextmenu = (e) => {
  e.preventDefault();
  menu(packActions(), e.clientX, e.clientY);
};
el("filePacks").oncontextmenu = e => { e.preventDefault(); menu(packActions("files"), e.clientX, e.clientY); };
el("new").onclick = () => send("editor", { mode: "new" });
el("remove").onclick = () => send("remove", { group: "apps" });
el("removeFiles").onclick = () => send("remove", { group: "files" });
el("import").onclick = () =>
  atButton("import", [
    ["From ZIP…", () => send("import", { zip: true })],
    ["From folder…", () => send("import", { zip: false })],
  ]);
el("apply").onclick = () => send("review", { restore: model.pack.default });
el("restore").onclick = () => send("review", { restore: true });
el("names").onchange = () => send("names", { value: el("names").checked });
el("openAtLogin").onchange = () => send("openAtLogin", { value: el("openAtLogin").checked });
el("offerApps").onchange = el("offerFiles").onchange = () => offerButton();
el("offerDownload").onclick = () => send("downloadPacks", offerChoice());
el("offerLater").onclick = el("offerSlimLater").onclick = () => send("skipPacks");
el("offerChoose").onclick = () => requestTab("manage");
el("offerClose").onclick = () => send("closeDownloads");
el("loginSettings").onclick = el("loginSettingsSlim").onclick = () => send("openLoginSettings");
el("slider").oninput = () => {
  size(el("slider").value);
};
el("slider").onchange = () => send("size", { value: +el("slider").value });
el("exact").onfocus = () => el("exact").select();
el("exact").onblur = () => {
  if (model && el("exact").value !== String(model.prefs.size))
    send("size", {
      value: /^\d+$/.test(el("exact").value)
        ? Math.max(24, Math.min(model.maxSize, +el("exact").value))
        : model.prefs.size,
    });
};
el("exact").onkeydown = (e) => {
  if (e.key === "Enter") el("exact").blur();
  if (e.key === "Escape") {
    el("exact").value = model.prefs.size;
    el("exact").blur();
    e.stopPropagation();
  }
};
el("reset").onclick = () => send("size", { value: 48 });
el("appearance").onclick = () => send("appearance");
el("brand").onclick = colorMenu;
el("savePack").onclick = () => send("savePack", { name: el("packName").value, author: el("author").value });
el("saveKey").onclick = () => {
  const k = { enabled: el("keyEnabled").checked, key: el("key").value };
  for (const label of ["Control", "Option", "Shift", "Command"])
    k[label.toLowerCase()] = el("mod-" + label).checked;
  send("saveKey", k);
};
document.addEventListener("pointerdown", (e) => {
  if (!el("menu").hidden && !el("menu").contains(e.target)) closeMenu();
});
document.addEventListener("contextmenu", (e) => e.preventDefault());
document.addEventListener("keydown", (e) => {
  if (activeDialog() || working || !model || !el("packOptions").hidden) return;
  if (!el("menu").hidden) {
    if (e.key === "Escape") {
      closeMenu();
      e.preventDefault();
    }
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      const choices = [...el("menu").querySelectorAll("button:enabled")];
      const i = choices.indexOf(document.activeElement);
      choices[(i + (e.key === "ArrowDown" ? 1 : -1) + choices.length) % choices.length]?.focus();
      e.preventDefault();
    }
    return;
  }
  if (["INPUT", "SELECT"].includes(e.target.tagName) && e.key !== "Escape") return;
  if ((e.target === el("launcherShortcut") || e.target.getAttribute?.("role") === "tab") &&
      (e.key === "Enter" || e.key === " ")) return;
  if (page === "manage" && e.key === "Escape") {
    requestTab("launcher");
    e.preventDefault();
    return;
  }
  const id = page === "launcher" ? "apps" : "preview";
  if (id === "apps") highlightHoveredApp(null);
  if (page === "manage" && !el("preview").contains(document.activeElement)) return;
  const items = id === "apps" ? filtered() : model.preview;
  let i = items.findIndex((item) => item.id === selected[id]);
  if (e.key === "F10" && e.shiftKey && i >= 0) {
    const r = el(id).children[i].getBoundingClientRect();
    tileMenu(items[i], r.left, r.top);
  } else if (e.key.startsWith("Arrow") && items.length) {
    const cols = Math.max(
      1,
      Math.floor(
        el(id).clientWidth /
          parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--cell")),
      ),
    );
    i =
      i < 0
        ? 0
        : Math.max(
            0,
            Math.min(
              items.length - 1,
              i + ({ ArrowLeft: -1, ArrowRight: 1, ArrowUp: -cols, ArrowDown: cols }[e.key] || 0),
            ),
          );
    selected[id] = items[i].id;
    grid(id, items);
    el(id).children[i].scrollIntoView({ block: "nearest", inline: "nearest" });
  } else if (page !== "launcher") return;
  else if (e.key === "Enter" && i >= 0) send("launch", { id: items[i].id });
  else if (e.key === "Escape" && !prefix) send("hide");
  else if (
    e.key === "Escape" ||
    e.key === "Backspace" ||
    (e.key.length === 1 && !e.metaKey && !e.ctrlKey && !e.altKey)
  ) {
    if (e.key === "Escape" || (e.key === "Backspace" && (e.ctrlKey || e.metaKey))) prefix = "";
    else if (e.key === "Backspace") prefix = Array.from(prefix).slice(0, -1).join("");
    else prefix += e.key;
    selected.apps = prefix ? filtered()[0]?.id || "" : "";
    grids();
    el("apps").scrollTop = 0;
  } else return;
  e.preventDefault();
});
let zoomAt = 0;
el("launcher").addEventListener(
  "wheel",
  (e) => {
    if (!(e.ctrlKey || e.metaKey) || working) return;
    e.preventDefault();
    if (Date.now() - zoomAt < 65 || !e.deltaY) return;
    zoomAt = Date.now();
    send("size", {
      value: Math.min(model.maxSize, Math.max(24, model.prefs.size + (e.deltaY < 0 ? 8 : -8))),
    });
  },
  { passive: false },
);
window.betterIcon = {
  update,
  packUpdateCount,
  packPreview,
  reset,
  tab,
  busy,
  editor,
  assignment,
  hotkey,
  keyStatus: (message, shortcut) => {
    text("keyStatus", message);
    showShortcut(shortcut);
  },
  doneDialog,
  showError: (id, message) => text(id, message),
};
tab("launcher", false);
send("ready");

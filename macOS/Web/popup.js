"use strict";
const el = (id) => document.getElementById(id);
const send = (action, data = {}) => window.webkit.messageHandlers.betterIcon.postMessage({ action, ...data });
const names = ["Clay", "Copper", "Mauve", "Ochre", "Sage", "Slate", "Stone", "Teal"];
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
  page = name;
  for (const id of ["launcher", "manage"]) {
    el(id).hidden = id !== name;
    el(id + "Tab").setAttribute("aria-selected", String(id === name));
  }
  closeMenu();
  if (focus) (name === "launcher" ? el("apps") : el("packs")).focus();
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
function packActions() {
  const p = model.pack;
  return [
    ["Customize…", () => send("editor", { mode: "customize" }), !p.default],
    ["Edit pack…", () => send("editor", { mode: "edit" }), p.personal],
    ["Export ZIP…", () => send("export"), p.personal],
    ["Restore built-in packs", () => send("unhide"), true],
  ];
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
  for (const name of names)
    for (const variant of ["dark", "light"]) {
      const color = name.toLowerCase();
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
function grid(id, items) {
  const area = el(id),
    previous = area.scrollTop;
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
    b.onclick = select;
    b.ondblclick = () => {
      if (id === "apps" && !working) send("launch", { id: item.id });
    };
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
function grids() {
  const visible = filtered();
  grid("apps", visible);
  grid("preview", model.preview);
  el("empty").hidden = visible.length !== 0;
  text(
    "empty",
    prefix
      ? "No apps match ‘" + prefix + "’. Backspace edits the filter. Escape clears it."
      : "No ArtCraft apps found. Right-click the menu bar icon to refresh or choose an apps folder.",
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
    pack = model.pack;
  document.documentElement.dataset.dark = String(model.dark);
  document.body.classList.toggle("iconOnly", !p.names);
  const options = model.packs.map((item) => new Option(item.title, item.id));
  el("packs").replaceChildren(...options);
  el("packs").value = pack.id;
  text(
    "detail",
    pack.default
      ? "Original icons for your installed apps. Restore defaults below to undo BetterIcon changes."
      : model.preview.length + " icons / " + (pack.personal ? "Personal pack" : "Built-in pack"),
  );
  el("remove").disabled = pack.default;
  el("names").checked = p.names;
  el("slider").max = model.maxSize;
  size(p.size);
  text("apply", pack.default ? "Restore ArtCraft defaults…" : "Apply icons…");
  text("version", "Better Icon for ArtCraft version " + model.version);
  const variant = p.variant === "auto" ? (model.dark ? "dark" : "light") : p.variant;
  el("brand").firstElementChild.src = model.brands[p.color + "_" + variant];
  el("brand").title = "BetterIcon app icon";
  el("appearance").innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true">' + glyphs[p.theme] + "</svg>";
  const nextTheme = appearanceOrder[(appearanceOrder.indexOf(p.theme) + 1) % 3];
  el("appearance").title = p.theme + " appearance. Switch to " + nextTheme + ".";
  grids();
  if (gen === viewGeneration && model.status) text("status", model.status);
}
function busy(message) {
  working = Boolean(message);
  el("busy").hidden = !working;
  el("busy").firstElementChild.textContent = message || "";
  for (const section of [el("launcher"), el("manage"), document.querySelector("nav")])
    section.inert = working;
  for (const dialog of document.querySelectorAll("dialog[open]")) dialog.inert = working;
  if (!working) for (const dialog of document.querySelectorAll("dialog")) dialog.inert = false;
  if (working) closeMenu();
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
    row.append(make("span", craft), file, choose, clear);
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
      l.append(i, document.createTextNode(label));
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
el("launcherTab").onclick = () => tab("launcher");
el("manageTab").onclick = () => tab("manage");
el("packs").onchange = () => send("select", { id: el("packs").value });
el("packs").oncontextmenu = (e) => {
  e.preventDefault();
  menu(packActions(), e.clientX, e.clientY);
};
el("new").onclick = () => send("editor", { mode: "new" });
el("remove").onclick = () => send("remove");
el("import").onclick = () =>
  atButton("import", [
    ["From ZIP…", () => send("import", { zip: true })],
    ["From folder…", () => send("import", { zip: false })],
  ]);
el("apply").onclick = () => send("review", { restore: model.pack.default });
el("restore").onclick = () => send("review", { restore: true });
el("names").onchange = () => send("names", { value: el("names").checked });
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
  if (activeDialog() || working || !model) return;
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
  if (page === "manage" && e.key === "Escape") {
    tab("launcher");
    e.preventDefault();
    return;
  }
  const id = page === "launcher" ? "apps" : "preview";
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
  reset,
  busy,
  editor,
  assignment,
  hotkey,
  keyStatus: (message) => text("keyStatus", message),
  doneDialog,
  showError: (id, message) => text(id, message),
};
tab("launcher", false);
send("ready");

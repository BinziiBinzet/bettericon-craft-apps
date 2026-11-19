"use strict";

let packAnchor, hoverRow, hoverTimer, hoverToken = 0, pointerPosition;

function setPackButtons(state) {
  for (const [key, pack] of [["packs", state.pack], ["filePacks", state.filePack]]) {
    const button = el(key);
    button.value = pack.id;
    const row = state.packs.find(item => item.id === pack.id) || pack;
    button.textContent = row.title + (row.status ? "  ·  " + row.status : "");
  }
}
function clearPackHover() {
  clearTimeout(hoverTimer);
  hoverToken++;
  hoverRow = null;
  const image = el("hoverPreview");
  image.onload = null;
  image.hidden = true;
  image.removeAttribute("src");
}
function closePackPicker(focus = false) {
  const list = document.getElementById("packOptions");
  if (!list || list.hidden) return;
  list.hidden = true;
  clearPackHover();
  pointerPosition = null;
  packAnchor.setAttribute("aria-expanded", "false");
  if (focus) packAnchor.focus();
}
function requestPackPreview(row) {
  if (row === hoverRow) return;
  clearPackHover();
  if (!row) return;
  hoverRow = row;
  if (row.dataset.preview !== "true") return;
  const token = hoverToken;
  hoverTimer = setTimeout(() => send("previewPack", { id: row.dataset.id, token }), 180);
}
function packPreview(id, token, url) {
  if (token !== hoverToken || !hoverRow || hoverRow.dataset.id !== id || el("packOptions").hidden) return;
  const image = el("hoverPreview");
  image.onload = () => {
    if (token !== hoverToken || !hoverRow || !image.naturalWidth) return;
    const list = el("packOptions").getBoundingClientRect(), row = hoverRow.getBoundingClientRect();
    let left = list.right + 5, top = row.top;
    if (left + image.offsetWidth > innerWidth || left + 214 > innerWidth) {
      left = list.left - 219;
      if (left < 4) {
        left = Math.max(4, Math.min(list.right - 214, innerWidth - 218));
        top = row.bottom + 4;
        if (top + 74 > innerHeight) top = row.top - 77;
      }
    }
    image.style.left = Math.max(4, left) + "px";
    image.style.top = Math.max(4, Math.min(top, innerHeight - 78)) + "px";
    image.hidden = false;
  };
  image.src = url;
}
function openPackPicker(group) {
  const anchor = el(group === "files" ? "filePacks" : "packs"), list = el("packOptions");
  if (packAnchor === anchor && !list.hidden) { closePackPicker(true); return; }
  closePackPicker();
  closeMenu();
  packAnchor = anchor;
  const options = model.packs.filter(p => group === "files" ? p.canFiles : p.canApps);
  list.replaceChildren(...options.map((pack, index) => {
    const row = document.createElement("div");
    row.id = "pack-option-" + index;
    row.setAttribute("role", "option");
    row.setAttribute("aria-selected", String(anchor.value === pack.id));
    row.dataset.id = pack.id;
    row.dataset.preview = String(pack.hasPreview);
    row.append(document.createTextNode(pack.title));
    const flag = document.createElement("span");
    flag.textContent = pack.status;
    row.append(flag);
    row.onclick = () => {
      closePackPicker(true);
      send("select", { id: pack.id, group });
    };
    return row;
  }));
  if (!list.children.length) return;
  list.setAttribute("aria-label", group === "files" ? "Project file icon packs" : "App icon packs");
  const pos = anchor.getBoundingClientRect();
  const below = innerHeight - pos.bottom - 8, above = pos.top - 8, up = below < 160 && above > below;
  const width = Math.min(Math.max(260, pos.width), 480, innerWidth - 12);
  Object.assign(list.style, {left: Math.max(6, Math.min(pos.left, innerWidth - width - 6)) + "px",
    width: width + "px", maxHeight: Math.min(300, Math.max(90, up ? above : below)) + "px",
    top: up ? "auto" : pos.bottom + 3 + "px", bottom: up ? innerHeight - pos.top + 3 + "px" : "auto"});
  list.hidden = false;
  anchor.setAttribute("aria-expanded", "true");
  const current = list.querySelector('[aria-selected="true"]') || list.firstElementChild;
  list.setAttribute("aria-activedescendant", current.id);
  current.scrollIntoView({block: "nearest"});
  list.focus({preventScroll: true});
}
document.addEventListener("DOMContentLoaded", () => {
  const list = el("packOptions");
  const rowAt = (x, y) => {
    const node = document.elementFromPoint(x, y)?.closest('[role="option"]');
    return node && list.contains(node) ? node : null;
  };
  list.onpointermove = e => {
    pointerPosition = [e.clientX, e.clientY];
    const row = rowAt(...pointerPosition);
    if (row) list.setAttribute("aria-activedescendant", row.id);
    requestPackPreview(row);
  };
  list.onpointerover = list.onpointermove;
  list.onpointerleave = () => { pointerPosition = null; clearPackHover(); };
  list.onscroll = () => { if (pointerPosition) requestPackPreview(rowAt(...pointerPosition)); };
  list.onkeydown = e => {
    const row = document.getElementById(list.getAttribute("aria-activedescendant"));
    let next;
    if (e.key === "Escape" || e.key === "Tab") { closePackPicker(true); if (e.key === "Tab") return; }
    else if (e.key === "Enter" || e.key === " ") row?.click();
    else if (e.key === "Home") next = list.firstElementChild;
    else if (e.key === "End") next = list.lastElementChild;
    else if (e.key === "ArrowDown") next = row?.nextElementSibling || row;
    else if (e.key === "ArrowUp") next = row?.previousElementSibling || row;
    else return;
    e.preventDefault();
    e.stopPropagation();
    if (next) {
      pointerPosition = null;
      list.querySelector(".keyboard-choice")?.classList.remove("keyboard-choice");
      next.classList.add("keyboard-choice");
      list.setAttribute("aria-activedescendant", next.id);
      next.scrollIntoView({block: "nearest"});
      requestPackPreview(next);
    }
  };
  for (const [button, group] of [["packs","apps"],["filePacks","files"]]) {
    el(button).addEventListener("keydown", e => {
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {e.preventDefault(); openPackPicker(group);}
    });
  }
  document.addEventListener("pointerdown", e => {
    if (!list.hidden && !list.contains(e.target) && e.target !== packAnchor) closePackPicker();
  });
  window.addEventListener("resize", () => closePackPicker());
});

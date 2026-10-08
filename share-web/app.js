import React from "react";
import { createRoot } from "react-dom/client";
import { ThinkingOrb } from "thinking-orbs";
import { initializeApp } from "https://www.gstatic.com/firebasejs/11.0.2/firebase-app.js";
import {
  getFirestore,
  doc,
  getDoc,
} from "https://www.gstatic.com/firebasejs/11.0.2/firebase-firestore.js";

const firebaseConfig = {
  apiKey: "AIzaSyCUdaJSYPVy37GFzD5Al2wlKfDRKdaTRN4",
  authDomain: "aestheticpass-818c6.firebaseapp.com",
  projectId: "aestheticpass-818c6",
  storageBucket: "aestheticpass-818c6.firebasestorage.app",
  messagingSenderId: "688009382588",
  appId: "1:688009382588:web:aba4134426075a70af1eb9",
  measurementId: "G-BN06X81GZE",
};

const DEMO = {
  procedure: "RF Microneedling",
  area: "Entire face",
  duration: "1 week ago",
  userName: "ÆSTHETIC JOURNEY member",
  beforePhotoPath: "/assets/beforew.jpg",
  afterPhotoPath: "/assets/afterw.jpg",
};

const app = initializeApp(firebaseConfig);
const db = getFirestore(app);

let orbRoot = null;

function shareIdFromPath() {
  const parts = location.pathname.split("/").filter(Boolean);
  if (parts[0] === "share" && parts[1]) return parts[1];
  const q = new URLSearchParams(location.search).get("id");
  return (q || "").trim();
}

function isMediaPath(value) {
  const v = (value || "").trim();
  return /^https?:\/\//i.test(v) || v.startsWith("/");
}

function setMedia(el, path) {
  if (!el) return;
  const v = (path || "").trim();
  if (isMediaPath(v)) {
    el.style.backgroundImage = `url("${v}")`;
    el.classList.add("has-image");
  }
}

function deepLink(shareId) {
  return shareId ? `aeglowup://share/${shareId}` : "aeglowup://";
}

function setupTabs() {
  const tabs = [...document.querySelectorAll(".tab[data-tab]")];
  const panelMilestones = document.getElementById("panelMilestones");
  const panelAbout = document.getElementById("panelAbout");

  function show(tabName) {
    const isMilestones = tabName === "milestones";
    tabs.forEach((tab) => {
      const active = tab.dataset.tab === tabName;
      tab.classList.toggle("tab-active", active);
      tab.setAttribute("aria-selected", active ? "true" : "false");
    });
    panelMilestones.hidden = !isMilestones;
    panelMilestones.classList.toggle("is-hidden", !isMilestones);
    panelAbout.hidden = isMilestones;
    panelAbout.classList.toggle("is-hidden", isMilestones);
  }

  tabs.forEach((tab) => {
    tab.addEventListener("click", () => show(tab.dataset.tab));
  });
}

function showLoading() {
  const loading = document.getElementById("loading");
  const shell = document.getElementById("shell");
  loading.hidden = false;
  shell.classList.add("is-loading");

  const mount = document.getElementById("orbRoot");
  if (!orbRoot) orbRoot = createRoot(mount);
  orbRoot.render(
    React.createElement(ThinkingOrb, {
      state: "working",
      size: 64,
      theme: "light",
      "aria-label": "Loading shared progress",
    })
  );
}

function hideLoading() {
  const loading = document.getElementById("loading");
  const shell = document.getElementById("shell");
  loading.hidden = true;
  shell.classList.remove("is-loading");
  if (orbRoot) {
    orbRoot.render(null);
  }
}

function render(data, shareId) {
  const title = (data.procedure || "Glow-up").trim() || "Glow-up";
  const area = (data.area || "").trim();
  const duration = (data.duration || "").trim();
  const user = (data.userName || "").trim();

  document.getElementById("title").textContent = title;
  document.getElementById("eyebrow").textContent = shareId
    ? "Shared glow-up"
    : "Preview";

  const bits = [user, area, duration].filter(Boolean);
  document.getElementById("meta").textContent = bits.join(" · ");

  setMedia(document.getElementById("beforeMedia"), data.beforePhotoPath);
  setMedia(document.getElementById("afterMedia"), data.afterPhotoPath);

  const open = document.getElementById("openApp");
  open.href = deepLink(shareId);

  open.addEventListener("click", () => {
    const started = Date.now();
    setTimeout(() => {
      if (document.hidden) return;
      if (Date.now() - started < 1800) {
        const isiOS = /iPhone|iPad|iPod/i.test(navigator.userAgent);
        location.href = isiOS
          ? document.getElementById("appStore").href
          : document.getElementById("playStore").href;
      }
    }, 1400);
  });
}

function renderMissing() {
  const card = document.getElementById("card");
  card.classList.add("error");
  document.getElementById("eyebrow").textContent = "Link unavailable";
  document.getElementById("title").textContent = "This share couldn’t be found";
  document.getElementById("meta").textContent = "";
  document.getElementById("teaser").textContent =
    "The link may have expired. Download ÆSTHETIC JOURNEY to explore live community results.";
  document.getElementById("openApp").href = "aeglowup://";
}

async function main() {
  setupTabs();
  const shareId = shareIdFromPath();

  if (!shareId) {
    render(DEMO, "");
    document.getElementById("teaser").textContent =
      "This is a local preview of the share page. Shared links look like /share/abc123 — visitors see a teaser, then get sent to download / open the app.";
    return;
  }

  showLoading();
  try {
    const snap = await getDoc(doc(db, "shared_progress", shareId));
    if (!snap.exists()) {
      renderMissing();
      return;
    }
    render(snap.data() || {}, shareId);
  } catch (err) {
    console.error(err);
    renderMissing();
  } finally {
    hideLoading();
  }
}

main();

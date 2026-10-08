(() => {
  const year = document.getElementById("year");
  if (year) year.textContent = String(new Date().getFullYear());

  const nav = document.getElementById("nav");

  const onScroll = () => {
    if (!nav) return;
    nav.classList.toggle("is-scrolled", window.scrollY > 24);
  };
  onScroll();
  window.addEventListener("scroll", onScroll, { passive: true });

  // —— Before / After slider (matches welcome_screen.dart) ——
  const stage = document.getElementById("baStage");
  const before = document.getElementById("baBefore");
  const line = document.getElementById("baLine");
  const handle = document.getElementById("baHandle");

  let split = 0.5;
  let dragging = false;

  function setSplit(fraction) {
    split = Math.min(0.92, Math.max(0.08, fraction));
    const pct = split * 100;
    if (before) before.style.clipPath = `inset(0 ${100 - pct}% 0 0)`;
    if (line) line.style.left = `${pct}%`;
    if (handle) {
      handle.style.left = `${pct}%`;
      handle.setAttribute("aria-valuenow", String(Math.round(pct)));
    }
  }

  function splitFromClientX(clientX) {
    if (!stage) return;
    const rect = stage.getBoundingClientRect();
    if (rect.width <= 0) return;
    setSplit((clientX - rect.left) / rect.width);
  }

  function onPointerDown(e) {
    dragging = true;
    stage?.setPointerCapture?.(e.pointerId);
    splitFromClientX(e.clientX);
    e.preventDefault();
  }

  function onPointerMove(e) {
    if (!dragging) return;
    splitFromClientX(e.clientX);
  }

  function onPointerUp(e) {
    dragging = false;
    try {
      stage?.releasePointerCapture?.(e.pointerId);
    } catch (_) {
      /* ignore */
    }
  }

  if (stage && before && line && handle) {
    setSplit(0.5);
    stage.addEventListener("pointerdown", onPointerDown);
    stage.addEventListener("pointermove", onPointerMove);
    stage.addEventListener("pointerup", onPointerUp);
    stage.addEventListener("pointercancel", onPointerUp);

    handle.addEventListener("keydown", (e) => {
      if (e.key === "ArrowLeft") {
        setSplit(split - 0.03);
        e.preventDefault();
      } else if (e.key === "ArrowRight") {
        setSplit(split + 0.03);
        e.preventDefault();
      }
    });
  }

  // —— Dual procedure orbit (welcome_screen2.dart) ——
  const INNER = [
    { src: "/assets/jelofiller.png", label: "LIP FILLER" },
    { src: "/assets/rhinoplastyjello.png", label: "RHINOPLASTY" },
    { src: "/assets/botoxjelli.png", label: "BOTOX" },
    { src: "/assets/hairtranspantjelo.png", label: "HAIR TRANSPLANT" },
    { src: "/assets/jellomicronedeling.png", label: "MICRONEEDLING" },
    { src: "/assets/blapherojellli.png", label: "SKIN BOOSTER" },
  ];
  const OUTER = [
    { src: "/assets/scarremoverjelli.png", label: "SCAR REMOVAL" },
    { src: "/assets/blapheroplastyjelli.png", label: "BLEPHAROPLASTY" },
    { src: "/assets/boobjobjelli.png", label: "BREAST" },
    { src: "/assets/tummytuckjelly.png", label: "TUMMY TUCK" },
    { src: "/assets/jawlinejelli.png", label: "JAWLINE" },
    { src: "/assets/faceliftjelli.png", label: "FACELIFT" },
    { src: "/assets/cheekfillerjelli.png", label: "CHEEK FILLER" },
  ];

  const orbitStage = document.getElementById("orbitStage");
  const orbitNodes = document.getElementById("orbitNodes");
  const orbitAura = document.getElementById("orbitAura");
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  function buildOrbitNodes() {
    if (!orbitNodes) return [];
    orbitNodes.innerHTML = "";
    const nodes = [];

    function addRing(items, ring, small) {
      items.forEach((item) => {
        const el = document.createElement("div");
        el.className = `orbit-node${small ? " is-small" : ""}`;
        el.dataset.ring = ring;
        el.innerHTML = `<span>${item.label}</span><img alt="" src="${item.src}" decoding="async" loading="lazy" />`;
        orbitNodes.appendChild(el);
        nodes.push({ el, ring, item });
      });
    }

    addRing(INNER, "inner", false);
    addRing(OUTER, "outer", true);
    return nodes;
  }

  function buildAuraRings() {
    if (!orbitAura) return [];
    orbitAura.innerHTML = "";
    const specs = [
      { mul: 0.2, phase: 0.55, soft: true },
      { mul: 0.28, phase: 0.35, soft: false },
      { mul: 0.42, phase: 0.0, soft: true },
    ];
    return specs.map((s) => {
      const span = document.createElement("span");
      span.dataset.mul = String(s.mul);
      span.dataset.phase = String(s.phase);
      span.dataset.soft = s.soft ? "1" : "0";
      orbitAura.appendChild(span);
      return { el: span, ...s };
    });
  }

  const nodes = buildOrbitNodes();
  const auras = buildAuraRings();
  const orbitStart = performance.now();
  const ORBIT_MS = 32000;
  const AURA_MS = 9000;

  function layoutOrbit(now) {
    if (!orbitStage || !nodes.length) return;
    const stageW = orbitStage.clientWidth;
    const stageH = orbitStage.clientHeight;
    const side = Math.min(stageW, stageH);
    const cx = stageW / 2;
    const cy = stageH / 2;
    // Fit both rings + labels inside the square (no spill onto logo/subtitle)
    const ringR = side * 0.28;
    const outerR = side * 0.405;
    const photoSize = side * 0.125;
    const outerPhoto = side * 0.082;

    const tOrbit = reduceMotion ? 0 : ((now - orbitStart) % ORBIT_MS) / ORBIT_MS;
    const tAura = reduceMotion ? 0.35 : ((now - orbitStart) % AURA_MS) / AURA_MS;
    const turn = tOrbit * Math.PI * 2;

    auras.forEach((a) => {
      const r = side * a.mul;
      const p = (tAura + a.phase) % 1;
      const pulse = 0.55 + 0.45 * Math.sin(p * Math.PI * 2);
      a.el.style.width = `${r * 2}px`;
      a.el.style.height = `${r * 2}px`;
      a.el.style.opacity = String((a.soft ? 0.18 : 0.3) * pulse);
      a.el.style.borderColor = a.soft
        ? `rgba(255,255,255,${0.28 + 0.28 * pulse})`
        : `rgba(234,230,229,${0.32 + 0.28 * pulse})`;
    });

    const innerNodes = nodes.filter((n) => n.ring === "inner");
    const outerNodes = nodes.filter((n) => n.ring === "outer");

    function place(list, radius, size, phaseOffset, flipBottom) {
      list.forEach((node, i) => {
        const angle =
          turn + phaseOffset + (i / list.length) * Math.PI * 2 - Math.PI / 2;
        const labelBelow = flipBottom && Math.sin(angle) > 0.08;
        const x = cx + radius * Math.cos(angle);
        const y = cy + radius * Math.sin(angle);
        const img = node.el.querySelector("img");
        const label = node.el.querySelector("span");
        if (img) {
          img.style.width = `${size}px`;
          img.style.height = `${size}px`;
        }
        if (label) label.style.visibility = "visible";
        node.el.classList.toggle("is-below", labelBelow);
        node.el.style.width = `${size + 18}px`;
        node.el.style.left = `${x}px`;
        node.el.style.top = `${y}px`;
        node.el.style.transform = labelBelow
          ? "translate(-50%, calc(-50% + 6px))"
          : "translate(-50%, calc(-50% - 6px))";
      });
    }

    place(innerNodes, ringR, photoSize, 0, false);
    place(outerNodes, outerR, outerPhoto, Math.PI / OUTER.length, true);
  }

  if (orbitStage && nodes.length) {
    const tick = (now) => {
      layoutOrbit(now);
      if (!reduceMotion) requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
    window.addEventListener("resize", () => layoutOrbit(performance.now()), {
      passive: true,
    });
  }

  const reveals = document.querySelectorAll(".reveal");
  function showReveal(el) {
    el.classList.add("is-in");
  }

  if ("IntersectionObserver" in window) {
    const io = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting || entry.intersectionRatio > 0) {
            showReveal(entry.target);
            io.unobserve(entry.target);
          }
        });
      },
      { rootMargin: "0px 0px -4% 0px", threshold: 0.01 },
    );
    reveals.forEach((el) => io.observe(el));
    // Safety: if IO never fires (some iOS cases), reveal after paint
    window.setTimeout(() => {
      reveals.forEach((el) => {
        if (!el.classList.contains("is-in")) showReveal(el);
      });
    }, 1200);
  } else {
    reveals.forEach(showReveal);
  }
})();

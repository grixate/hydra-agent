(() => {
  const clamp = (value, min, max) => Math.max(min, Math.min(max, value));
  const actions = {
    adopt: { label: "ADOPT", color: "#75d4ad", x: 0.27, y: 0.31 },
    resist: { label: "RESIST", color: "#ed856d", x: 0.76, y: 0.31 },
    ignore: { label: "WAIT", color: "#d7b969", x: 0.28, y: 0.76 },
    share: { label: "SHARE", color: "#8aa2f7", x: 0.76, y: 0.76 }
  };

  function initStudyCockpit() {
    const button = document.querySelector("#build-context");
    if (!button) return;
    button.addEventListener("click", () => {
      const url = button.dataset.studyUrl;
      if (url) {
        window.location.assign(url);
        return;
      }
      const target = document.querySelector("#context-preview");
      button.innerHTML = "Context ready <span>✓</span>";
      button.style.background = "#2f6c55";
      target.scrollIntoView({ behavior: "smooth", block: "center" });
    });
  }

  function initStudyWorkspace() {
    const workspace = document.querySelector("#study-workspace");
    if (!workspace) return;

    const tabs = Array.from(document.querySelectorAll(".study-tab"));
    const panels = Array.from(document.querySelectorAll("[data-study-panel]"));
    const traceToggle = document.querySelector("#toggle-research-trace");
    const trace = document.querySelector("#research-trace");
    const selectTab = (tab, focus = false) => {
      const selected = tab.dataset.studyTab;
      tabs.forEach((item) => {
        const active = item === tab;
        item.classList.toggle("active", active);
        item.setAttribute("aria-selected", String(active));
        item.tabIndex = active ? 0 : -1;
      });
      panels.forEach((panel) => {
        const active = panel.dataset.studyPanel === selected;
        panel.hidden = !active;
        panel.classList.toggle("active", active);
      });
      if (focus) tab.focus();
    };

    tabs.forEach((tab, index) => {
      const panel = panels.find((item) => item.dataset.studyPanel === tab.dataset.studyTab);
      const id = `study-tab-${tab.dataset.studyTab}`;
      tab.id = id;
      tab.setAttribute("aria-controls", panel ? `study-panel-${tab.dataset.studyTab}` : "");
      tab.setAttribute("aria-selected", String(tab.classList.contains("active")));
      tab.tabIndex = tab.classList.contains("active") ? 0 : -1;
      if (panel) {
        panel.id = `study-panel-${tab.dataset.studyTab}`;
        panel.setAttribute("role", "tabpanel");
        panel.setAttribute("aria-labelledby", id);
      }

      tab.addEventListener("click", () => selectTab(tab));
      tab.addEventListener("keydown", (event) => {
        let next = null;
        if (event.key === "ArrowRight" || event.key === "ArrowDown") next = tabs[(index + 1) % tabs.length];
        if (event.key === "ArrowLeft" || event.key === "ArrowUp") next = tabs[(index - 1 + tabs.length) % tabs.length];
        if (event.key === "Home") next = tabs[0];
        if (event.key === "End") next = tabs[tabs.length - 1];
        if (next) {
          event.preventDefault();
          selectTab(next, true);
        }
      });
    });

    if (traceToggle && trace) {
      traceToggle.setAttribute("aria-controls", "research-trace");
      traceToggle.setAttribute("aria-expanded", String(!trace.hidden));
      traceToggle.addEventListener("click", () => {
        trace.hidden = !trace.hidden;
        traceToggle.setAttribute("aria-expanded", String(!trace.hidden));
        traceToggle.querySelector("span").textContent = trace.hidden ? "⌄" : "⌃";
      });
    }
  }

  function initPendingRun() {
    const pendingRun = document.querySelector("[data-pending-run='true']");
    if (!pendingRun) return;

    window.setTimeout(() => window.location.reload(), 1400);
  }

  function initPendingResearch() {
    const workspace = document.querySelector("[data-pending-research]");
    if (!workspace) return;

    const storageKey = `hydra-research-refresh:${window.location.pathname}`;
    if (workspace.dataset.pendingResearch !== "true") {
      try { window.sessionStorage.removeItem(storageKey); } catch (_error) { /* storage is optional */ }
      return;
    }

    let attempts;
    try {
      attempts = Number(window.sessionStorage.getItem(storageKey) || 0);
    } catch (_error) {
      const status = document.querySelector("#research-auto-status");
      if (status) status.textContent = "Research is running. Reload when you are ready to check progress.";
      return;
    }
    if (attempts >= 40) {
      const status = document.querySelector("#research-auto-status");
      if (status) status.textContent = "Research is taking longer than expected. Reload when you are ready to check again.";
      return;
    }

    window.sessionStorage.setItem(storageKey, String(attempts + 1));
    window.setTimeout(() => window.location.reload(), 1600);
  }

  function initRunPreflights() {
    document.querySelectorAll(".scenario-run-form").forEach((form) => {
      const select = form.querySelector("select[name='mode']");
      const preflight = form.querySelector("[data-run-preflight]");
      if (!select || !preflight) return;

      const update = () => {
        const option = select.selectedOptions[0];
        const population = Number(option.dataset.agentCount || 0);
        const events = Number(preflight.dataset.eventCount || 0);
        preflight.querySelector("[data-projection-count]").textContent = (population * events).toLocaleString();
        preflight.querySelector("[data-model-call-count]").textContent = Number(option.dataset.modelCalls || 0).toLocaleString();
      };

      select.addEventListener("change", update);
      update();
    });
  }

  function initObservatory() {
    const root = document.querySelector("#observatory");
    const canvas = document.querySelector("#simulation-field");
    const particleCanvas = document.querySelector("#simulation-particles");
    if (!root || !canvas) return;

    const snapshots = JSON.parse(root.dataset.snapshots);
    const patternInsights = JSON.parse(root.dataset.patternInsights || "[]");
    const ctx = canvas.getContext("2d");
    const gl = particleCanvas && particleCanvas.getContext("webgl", { alpha: true, antialias: false });
    const scrubber = document.querySelector("#time-scrubber");
    const pauseButton = document.querySelector("#pause-play");
    const zoomOutButton = document.querySelector("#zoom-out");
    const zoomInButton = document.querySelector("#zoom-in");
    const zoomLens = document.querySelector("#zoom-lens");
    const traceButton = document.querySelector("#representative-trace");
    const traceCard = document.querySelector("#trace-card");
    const traceUrlBase = root.dataset.traceUrlBase;
    const reducedMotionQuery = window.matchMedia("(prefers-reduced-motion: reduce)");
    let tick = Number(scrubber.value) - 1;
    let paused = reducedMotionQuery.matches;
    let mode = "constellation";
    let frame = 0;
    let particles = [];
    let openTraceAgentId = null;
    let selectedClusterIndex = Math.max(0, snapshots[tick].clusters.findIndex((cluster) => cluster.persona_id === "privacy"));
    let zoom = 1;
    let pixelScale = 1;
    const webglState = gl ? initWebGL(gl) : null;
    root.dataset.renderer = webglState ? "webgl" : "canvas2d";

    function resize() {
      const rect = canvas.getBoundingClientRect();
      pixelScale = Math.min(window.devicePixelRatio || 1, 2);
      canvas.width = Math.floor(rect.width * pixelScale);
      canvas.height = Math.floor(rect.height * pixelScale);
      ctx.setTransform(pixelScale, 0, 0, pixelScale, 0, 0);
      if (particleCanvas && gl) {
        particleCanvas.width = canvas.width;
        particleCanvas.height = canvas.height;
        gl.viewport(0, 0, particleCanvas.width, particleCanvas.height);
      }
    }

    function initWebGL(context) {
      const vertexSource = `
        attribute vec2 a_position;
        attribute vec4 a_color;
        attribute float a_size;
        varying vec4 v_color;
        void main() {
          gl_Position = vec4(a_position, 0.0, 1.0);
          gl_PointSize = a_size;
          v_color = a_color;
        }
      `;
      const fragmentSource = `
        precision mediump float;
        varying vec4 v_color;
        void main() {
          vec2 point = gl_PointCoord - vec2(0.5);
          if (dot(point, point) > 0.25) discard;
          gl_FragColor = v_color;
        }
      `;

      function shader(type, source) {
        const compiled = context.createShader(type);
        context.shaderSource(compiled, source);
        context.compileShader(compiled);
        if (!context.getShaderParameter(compiled, context.COMPILE_STATUS)) return null;
        return compiled;
      }

      const vertex = shader(context.VERTEX_SHADER, vertexSource);
      const fragment = shader(context.FRAGMENT_SHADER, fragmentSource);
      if (!vertex || !fragment) return null;

      const program = context.createProgram();
      context.attachShader(program, vertex);
      context.attachShader(program, fragment);
      context.linkProgram(program);
      if (!context.getProgramParameter(program, context.LINK_STATUS)) return null;

      context.useProgram(program);
      context.enable(context.BLEND);
      context.blendFunc(context.SRC_ALPHA, context.ONE_MINUS_SRC_ALPHA);

      return {
        program,
        buffer: context.createBuffer(),
        position: context.getAttribLocation(program, "a_position"),
        color: context.getAttribLocation(program, "a_color"),
        size: context.getAttribLocation(program, "a_size")
      };
    }

    function colorChannels(hex) {
      const value = String(hex || "#ffffff").replace("#", "");
      return [0, 2, 4].map((offset) => parseInt(value.slice(offset, offset + 2), 16) / 255);
    }

    function renderWebGLParticles(width, height) {
      if (!gl || !webglState) return false;

      gl.clearColor(0, 0, 0, 0);
      gl.clear(gl.COLOR_BUFFER_BIT);
      if (mode === "pattern" || zoomMode() !== "COHORTS") return false;

      const values = [];
      particles.forEach((particle) => {
        const floatX = Math.sin(frame / 42 + particle.drift) * 2.2;
        const floatY = Math.cos(frame / 50 + particle.phase) * 2.2;
        const point = viewPoint(particle.x, particle.y, width, height);
        const x = ((point.x + floatX) / width) * 2 - 1;
        const y = 1 - ((point.y + floatY) / height) * 2;
        const opacity = mode === "evidence" ? particle.cluster.confidence + 0.22 : 0.62;
        const size = mode === "uncertainty" ? 2.1 + particle.cluster.uncertainty * 4 : 2.2;
        const [red, green, blue] = colorChannels(particle.cluster.color);
        values.push(x, y, red, green, blue, Math.min(opacity, 1), size * 2 * pixelScale);
      });

      const stride = 7 * Float32Array.BYTES_PER_ELEMENT;
      gl.useProgram(webglState.program);
      gl.bindBuffer(gl.ARRAY_BUFFER, webglState.buffer);
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(values), gl.DYNAMIC_DRAW);
      gl.enableVertexAttribArray(webglState.position);
      gl.vertexAttribPointer(webglState.position, 2, gl.FLOAT, false, stride, 0);
      gl.enableVertexAttribArray(webglState.color);
      gl.vertexAttribPointer(webglState.color, 4, gl.FLOAT, false, stride, 2 * Float32Array.BYTES_PER_ELEMENT);
      gl.enableVertexAttribArray(webglState.size);
      gl.vertexAttribPointer(webglState.size, 1, gl.FLOAT, false, stride, 6 * Float32Array.BYTES_PER_ELEMENT);
      gl.drawArrays(gl.POINTS, 0, particles.length);
      return true;
    }

    function seeded(value) {
      const x = Math.sin(value * 12.9898) * 43758.5453;
      return x - Math.floor(x);
    }

    function buildParticles() {
      particles = [];
      snapshots[tick].clusters.forEach((cluster, clusterIndex) => {
        const basin = actions[cluster.action];
        // Keep rendering cost proportional to visible complexity rather than the
        // simulated population. The aggregate counts remain available to the
        // report and accessible summary; the canvas is only a sampled view.
        const count = Math.max(36, Math.min(160, Math.round(Math.sqrt(cluster.count) * 3)));
        for (let i = 0; i < count; i += 1) {
          const a = seeded((i + 1) * (clusterIndex + 3));
          const b = seeded((i + 7) * (clusterIndex + 9));
          particles.push({
            cluster,
            x: clamp(cluster.x * 0.42 + basin.x * 0.58 + (a - 0.5) * 0.14, 0.04, 0.96),
            y: clamp(cluster.y * 0.42 + basin.y * 0.58 + (b - 0.5) * 0.14, 0.05, 0.94),
            drift: a * Math.PI * 2,
            phase: b * Math.PI * 2
          });
        }
      });
    }

    function viewCoordinate(value) {
      return clamp(0.5 + (value - 0.5) * zoom, -0.1, 1.1);
    }

    function viewPoint(x, y, width, height) {
      return { x: viewCoordinate(x) * width, y: viewCoordinate(y) * height };
    }

    function zoomMode() {
      if (zoom < 0.9) return "DENSITY";
      if (zoom > 1.45) return "SAMPLES";
      return "COHORTS";
    }

    function refreshZoomLens() {
      const lens = zoomMode();
      if (zoomLens) zoomLens.textContent = lens;
      const modeHints = {
        basins: "Action basins · color identifies the projected action",
        pattern: "Pattern flow · event → saved rule → projected action",
        evidence: "Evidence overlay · brighter = higher recorded confidence; dimmer = more assumption-led",
        uncertainty: "Uncertainty overlay · larger marks = lower confidence"
      };
      document.querySelector("#field-mode-hint").textContent = modeHints[mode] || (lens === "DENSITY" ? "Far lens · aggregate density, not individual agents" : (lens === "SAMPLES" ? "Close lens · representative sampled points" : "Population weather · aggregate cohorts"));
    }

    function drawDensity(snapshot, width, height) {
      snapshot.clusters.forEach((cluster) => {
        const basin = actions[cluster.action];
        const point = viewPoint(cluster.x * 0.42 + basin.x * 0.58, cluster.y * 0.42 + basin.y * 0.58, width, height);
        const radius = Math.max(24, Math.min(105, Math.sqrt(cluster.count) * 2.1));
        const glow = ctx.createRadialGradient(point.x, point.y, 2, point.x, point.y, radius);
        glow.addColorStop(0, `${cluster.color}9c`);
        glow.addColorStop(0.5, `${cluster.color}35`);
        glow.addColorStop(1, `${cluster.color}00`);
        ctx.fillStyle = glow;
        ctx.beginPath(); ctx.arc(point.x, point.y, radius, 0, Math.PI * 2); ctx.fill();
      });
    }

    function drawRepresentativeSamples(width, height) {
      const samplePerCohort = 18;
      particles.forEach((particle, index) => {
        if (index % Math.max(1, Math.ceil(particles.length / (samplePerCohort * snapshots[tick].clusters.length))) !== 0) return;
        const point = viewPoint(particle.x, particle.y, width, height);
        ctx.fillStyle = `${particle.cluster.color}d4`;
        ctx.beginPath(); ctx.arc(point.x, point.y, 3.1, 0, Math.PI * 2); ctx.fill();
      });
    }

    function drawBasin(key, width, height) {
      const basin = actions[key];
      const x = basin.x * width;
      const y = basin.y * height;
      const radius = Math.min(width, height) * 0.13;
      const glow = ctx.createRadialGradient(x, y, 2, x, y, radius);
      const alpha = mode === "uncertainty" ? "2b" : "20";
      glow.addColorStop(0, `${basin.color}48`);
      glow.addColorStop(0.55, `${basin.color}${alpha}`);
      glow.addColorStop(1, `${basin.color}00`);
      ctx.fillStyle = glow;
      ctx.beginPath(); ctx.arc(x, y, radius, 0, Math.PI * 2); ctx.fill();
      ctx.fillStyle = `${basin.color}cc`;
      ctx.font = "500 10px DM Mono, monospace";
      ctx.textAlign = "center";
      ctx.fillText(basin.label, x, y + 4);
    }

    function drawFlowArrow(fromX, fromY, toX, toY, color) {
      const control = Math.max(28, (toX - fromX) * 0.32);
      ctx.strokeStyle = `${color}b8`;
      ctx.lineWidth = 1.35;
      ctx.beginPath();
      ctx.moveTo(fromX, fromY);
      ctx.bezierCurveTo(fromX + control, fromY, toX - control, toY, toX, toY);
      ctx.stroke();

      const angle = Math.atan2(toY - fromY, toX - (toX - control));
      ctx.fillStyle = `${color}d9`;
      ctx.beginPath();
      ctx.moveTo(toX, toY);
      ctx.lineTo(toX - 6 * Math.cos(angle - Math.PI / 6), toY - 6 * Math.sin(angle - Math.PI / 6));
      ctx.lineTo(toX - 6 * Math.cos(angle + Math.PI / 6), toY - 6 * Math.sin(angle + Math.PI / 6));
      ctx.closePath();
      ctx.fill();
    }

    function drawFlowLabel(text, x, y, color, align = "left") {
      ctx.fillStyle = color;
      ctx.font = "500 9px DM Mono, monospace";
      ctx.textAlign = align;
      ctx.fillText(text, x, y);
    }

    function drawPatternFlow(snapshot, width, height) {
      const clusters = snapshot.clusters.slice(0, 6);
      const laneHeight = Math.max(58, Math.min(84, height / (clusters.length + 1)));
      const sourceX = width * 0.07;
      const ruleX = width * 0.42;

      drawFlowLabel("EVENT", sourceX, 35, "#91aaa0");
      drawFlowLabel("STORED RULE", ruleX, 35, "#91aaa0");
      drawFlowLabel("ACTION", width * 0.83, 35, "#91aaa0");

      clusters.forEach((cluster, index) => {
        const y = Math.min(height - 36, 62 + laneHeight * index);
        const basin = actions[cluster.action];
        const actionX = basin.x * width;
        const actionY = basin.y * height;
        const color = cluster.color;
        const rule = cluster.dominant_pattern.length > 34 ? `${cluster.dominant_pattern.slice(0, 31)}…` : cluster.dominant_pattern;

        ctx.fillStyle = `${color}33`;
        ctx.fillRect(sourceX - 6, y - 10, 4, 20);
        drawFlowLabel(cluster.persona.toUpperCase(), sourceX + 4, y - 3, "#c7d8d0");
        drawFlowLabel(snapshot.event, sourceX + 4, y + 10, "#789087");
        drawFlowArrow(sourceX + 130, y, ruleX - 12, y, color);

        ctx.fillStyle = "rgba(27, 47, 41, .88)";
        ctx.strokeStyle = `${color}70`;
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.rect(ruleX - 10, y - 14, 194, 28);
        ctx.fill(); ctx.stroke();
        drawFlowLabel(rule, ruleX, y + 3, "#e4f0e9");
        drawFlowArrow(ruleX + 190, y, actionX - 10, actionY, color);
        drawFlowLabel(`${cluster.action} · ${Math.round(cluster.count).toLocaleString()}`, actionX, actionY - 18, `${color}ee`, "center");
      });
    }

    function draw() {
      const width = canvas.clientWidth;
      const height = canvas.clientHeight;
      ctx.clearRect(0, 0, width, height);
      Object.keys(actions).forEach((key) => drawBasin(key, width, height));
      const selectedTick = snapshots[tick];
      const webglParticles = renderWebGLParticles(width, height);
      const ripple = (Math.sin(frame / 20) + 1) * 0.5;
      const rippleX = width * 0.5;
      const rippleY = height * 0.5;
      ctx.strokeStyle = `rgba(119, 220, 166, ${0.16 - ripple * 0.08})`;
      ctx.lineWidth = 1;
      ctx.beginPath(); ctx.arc(rippleX, rippleY, 30 + ripple * 120, 0, Math.PI * 2); ctx.stroke();
      if (mode === "pattern") {
        drawPatternFlow(selectedTick, width, height);
      } else if (zoomMode() === "DENSITY") {
        drawDensity(selectedTick, width, height);
      } else if (zoomMode() === "SAMPLES") {
        drawRepresentativeSamples(width, height);
      } else if (!webglParticles) {
        particles.forEach((particle) => {
          const floatX = Math.sin(frame / 42 + particle.drift) * 2.2;
          const floatY = Math.cos(frame / 50 + particle.phase) * 2.2;
          const point = viewPoint(particle.x, particle.y, width, height);
          const x = point.x + floatX;
          const y = point.y + floatY;
          const opacity = mode === "evidence" ? (particle.cluster.confidence + 0.22) : 0.62;
          const size = mode === "uncertainty" ? 2.1 + particle.cluster.uncertainty * 4 : 2.2;
          ctx.fillStyle = particle.cluster.color + Math.round(opacity * 255).toString(16).padStart(2, "0");
          ctx.beginPath(); ctx.arc(x, y, size, 0, Math.PI * 2); ctx.fill();
        });
      }
      frame += 1;
      if (!paused) requestAnimationFrame(draw);
    }

    function currentCluster() {
      return snapshots[tick].clusters[selectedClusterIndex] || snapshots[tick].clusters[0];
    }

    function patternInsightFor(patternName) {
      const baseName = patternName.replace(/ · (control-first|manager-recognition) hypothesis$/, "");
      return patternInsights.find((insight) => insight.name === baseName);
    }

    function groundingPill(className, label) {
      const pill = document.createElement("span");
      pill.className = `source-pill ${className}`;
      pill.textContent = label;
      return pill;
    }

    function traceElement(tag, className, text) {
      const element = document.createElement(tag);
      if (className) element.className = className;
      if (text) element.textContent = text;
      return element;
    }

    function closeTrace() {
      if (!traceCard) return;
      traceCard.hidden = true;
      traceCard.replaceChildren();
      openTraceAgentId = null;
    }

    function renderTrace(trace) {
      if (!traceCard) return;
      const heading = traceElement("div", "trace-card-heading");
      heading.append(traceElement("span", "trace-card-label", "REPRESENTATIVE TRACE"));
      heading.append(traceElement("b", "", trace.persona));

      const disclosure = traceElement("p", "trace-disclosure", trace.parameters_disclosure);
      const parameters = traceElement("div", "trace-parameters");
      Object.entries(trace.parameters || {}).forEach(([key, value]) => {
        parameters.append(traceElement("span", "", `${key.replaceAll("_", " ")} · ${Math.round(value * 100)}%`));
      });

      const timeline = traceElement("ol", "trace-timeline");
      (trace.trace || []).forEach((step) => {
        const item = traceElement("li", "");
        item.append(traceElement("span", "", `${step.label} · ${step.event}`));
        item.append(traceElement("b", "", `${step.decision} · ${Math.round(step.probability * 100)}%`));
        item.append(traceElement("small", "", step.matched_patterns.join(", ")));
        timeline.append(item);
      });

      traceCard.replaceChildren(heading, disclosure, parameters, timeline);
      traceCard.hidden = false;
    }

    async function loadTrace(agentId) {
      if (!traceCard || !traceUrlBase || !agentId) return;
      traceButton.disabled = true;
      traceButton.querySelector("b").textContent = "Loading representative trace…";

      try {
        const response = await fetch(`${traceUrlBase}/${encodeURIComponent(agentId)}/trace`, { headers: { Accept: "application/json" } });
        if (!response.ok) throw new Error("Trace unavailable");
        const payload = await response.json();
        renderTrace(payload.data);
        openTraceAgentId = agentId;
      } catch (_error) {
        traceCard.replaceChildren(traceElement("p", "trace-error", "The representative trace is unavailable for this replay."));
        traceCard.hidden = false;
      } finally {
        traceButton.disabled = false;
        traceButton.querySelector("b").textContent = "Inspect representative trace";
      }
    }

    function refreshInsight(cluster) {
      const insight = patternInsightFor(cluster.dominant_pattern);
      document.querySelector("#selected-persona").textContent = cluster.persona.toUpperCase();
      document.querySelector("#pattern-name").textContent = cluster.dominant_pattern;
      const resistance = cluster.action === "resist";
      document.querySelector("#selected-title").textContent = insight ? `${cluster.persona}: ${insight.name}` : (resistance ? "Resistance is about control, not certificates." : `${cluster.persona} is moving toward ${cluster.action}.`);
      document.querySelector("#selected-summary").textContent = insight ? `When ${sentenceFragment(insight.condition)}, the group reads the situation as ${sentenceFragment(insight.interpretation)}. Motivation: ${sentenceFragment(insight.motivation)}.` : (resistance ? "When the block becomes visible by default, this group reads it as HR surveillance—not a career signal." : "This cohort is responding to the current event through an aggregate action pattern.");
      canvas.setAttribute("aria-label", `Selected cohort: ${cluster.persona}. Projected action: ${cluster.action}. Use the arrow keys to explore cohorts.`);

      const groundingRow = document.querySelector("#grounding-row");
      if (groundingRow) {
        groundingRow.replaceChildren();
        if (insight) {
          groundingRow.append(
            groundingPill(insight.evidence_count > 0 ? "data" : "assumption", insight.evidence_count > 0 ? `${insight.evidence_count} linked evidence` : "No linked evidence"),
            groundingPill(insight.assumption_count > 0 ? "assumption" : "data", insight.assumption_count > 0 ? `${insight.assumption_count} ${insight.assumption_count === 1 ? "assumption" : "assumptions"}` : "No recorded assumptions")
          );
        } else {
          groundingRow.append(groundingPill("assumption", "Aggregate demo · no individual trace"));
        }
      }

      if (traceButton) {
        const representativeAgentId = cluster.representative_agent_id;
        traceButton.dataset.agentId = representativeAgentId || "";
        traceButton.disabled = !representativeAgentId;
        if (openTraceAgentId && openTraceAgentId !== representativeAgentId) closeTrace();
      }
    }

    function sentenceFragment(value) {
      const text = String(value || "the rule becomes active").trim().replace(/[.!?]+$/, "");
      return text.charAt(0).toLowerCase() + text.slice(1);
    }

    function update() {
      const snap = snapshots[tick];
      selectedClusterIndex = clamp(selectedClusterIndex, 0, Math.max(0, snap.clusters.length - 1));
      document.querySelector("#replay-day").textContent = snap.label;
      document.querySelector("#replay-event").textContent = snap.event;
      document.querySelector("#event-notice").textContent = `${snap.label} · ${snap.event}`;
      document.querySelector("#cost-used").textContent = `$${snap.cost.actual_usd.toFixed(2)}`;
      ["adopt", "resist", "ignore", "share"].forEach((key) => {
        document.querySelector(`#metric-${key}`).textContent = `${Math.round(snap.metrics[key] * 100)}%`;
      });
      document.querySelectorAll(".event-item").forEach((item, index) => {
        const selected = index === tick;
        item.classList.toggle("selected", selected);
        item.setAttribute("aria-pressed", String(selected));
      });
      buildParticles();
      refreshInsight(currentCluster());
      if (paused) draw();
    }

    if (paused) {
      pauseButton.textContent = "▶";
      pauseButton.setAttribute("aria-label", "Resume replay");
      pauseButton.setAttribute("aria-pressed", "true");
    } else {
      pauseButton.setAttribute("aria-pressed", "false");
    }

    resize(); update(); refreshZoomLens(); draw();
    window.addEventListener("resize", () => { resize(); if (paused) draw(); });
    scrubber.addEventListener("input", (event) => { tick = Number(event.target.value) - 1; update(); });
    document.querySelectorAll(".event-item").forEach((item) => item.addEventListener("click", () => { tick = Number(item.dataset.tick) - 1; scrubber.value = tick + 1; update(); }));
    const modeButtons = Array.from(document.querySelectorAll(".mode-switcher button"));
    function selectMode(button, focus = false) {
      mode = button.dataset.mode;
      modeButtons.forEach((item) => {
        const selected = item === button;
        item.classList.toggle("active", selected);
        item.setAttribute("aria-selected", String(selected));
        item.tabIndex = selected ? 0 : -1;
      });
      if (focus) button.focus();
      refreshZoomLens();
      if (paused) draw();
    }
    modeButtons.forEach((button, index) => {
      button.addEventListener("click", () => selectMode(button));
      button.addEventListener("keydown", (event) => {
        let nextIndex = index;
        if (event.key === "ArrowRight") nextIndex = (index + 1) % modeButtons.length;
        if (event.key === "ArrowLeft") nextIndex = (index - 1 + modeButtons.length) % modeButtons.length;
        if (event.key === "Home") nextIndex = 0;
        if (event.key === "End") nextIndex = modeButtons.length - 1;
        if (nextIndex !== index) {
          event.preventDefault();
          selectMode(modeButtons[nextIndex], true);
        }
      });
    });
    pauseButton.addEventListener("click", () => {
      paused = !paused;
      pauseButton.textContent = paused ? "▶" : "Ⅱ";
      pauseButton.setAttribute("aria-label", paused ? "Resume replay" : "Pause replay");
      pauseButton.setAttribute("aria-pressed", String(paused));
      if (!paused) requestAnimationFrame(draw);
    });
    reducedMotionQuery.addEventListener("change", (event) => {
      if (!event.matches || paused) return;
      paused = true;
      pauseButton.textContent = "▶";
      pauseButton.setAttribute("aria-label", "Resume replay");
      pauseButton.setAttribute("aria-pressed", "true");
      draw();
    });
    function changeZoom(amount) {
      zoom = clamp(Math.round((zoom + amount) * 100) / 100, 0.72, 1.9);
      refreshZoomLens();
      if (paused) draw();
    }
    if (zoomOutButton) zoomOutButton.addEventListener("click", () => changeZoom(-0.2));
    if (zoomInButton) zoomInButton.addEventListener("click", () => changeZoom(0.2));
    canvas.addEventListener("wheel", (event) => { event.preventDefault(); changeZoom(event.deltaY > 0 ? -0.12 : 0.12); }, { passive: false });
    if (traceButton) traceButton.addEventListener("click", () => {
      const agentId = traceButton.dataset.agentId;
      if (openTraceAgentId === agentId) closeTrace(); else loadTrace(agentId);
    });
    document.querySelector("#reset-view").addEventListener("click", () => { tick = Math.min(1, snapshots.length - 1); zoom = 1; scrubber.value = tick + 1; update(); refreshZoomLens(); });
    const whyButton = document.querySelector("#why-button");
    if (whyButton) whyButton.addEventListener("click", () => {
      const evidenceButton = modeButtons.find((button) => button.dataset.mode === "evidence");
      if (evidenceButton) selectMode(evidenceButton, true);
    });
    function selectCluster(index) {
      const clusters = snapshots[tick].clusters;
      if (clusters.length === 0) return;
      selectedClusterIndex = (index + clusters.length) % clusters.length;
      refreshInsight(currentCluster());
    }
    canvas.addEventListener("keydown", (event) => {
      if (["ArrowRight", "ArrowDown"].includes(event.key)) {
        event.preventDefault();
        selectCluster(selectedClusterIndex + 1);
      }
      if (["ArrowLeft", "ArrowUp"].includes(event.key)) {
        event.preventDefault();
        selectCluster(selectedClusterIndex - 1);
      }
      if (event.key === "Home") {
        event.preventDefault();
        selectCluster(0);
      }
      if (event.key === "End") {
        event.preventDefault();
        selectCluster(snapshots[tick].clusters.length - 1);
      }
    });
    canvas.addEventListener("click", (event) => {
      const rect = canvas.getBoundingClientRect();
      const x = 0.5 + (((event.clientX - rect.left) / rect.width) - 0.5) / zoom;
      const y = 0.5 + (((event.clientY - rect.top) / rect.height) - 0.5) / zoom;
      const closest = snapshots[tick].clusters.reduce((best, cluster) => {
        const basin = actions[cluster.action];
        const cx = cluster.x * 0.42 + basin.x * 0.58;
        const cy = cluster.y * 0.42 + basin.y * 0.58;
        return Math.hypot(x - cx, y - cy) < Math.hypot(x - best.x, y - best.y) ? { cluster, x: cx, y: cy } : best;
      }, { cluster: currentCluster(), x: 0, y: 0 }).cluster;
      selectCluster(snapshots[tick].clusters.indexOf(closest));
    });
  }

  document.addEventListener("DOMContentLoaded", () => { initStudyCockpit(); initStudyWorkspace(); initPendingRun(); initPendingResearch(); initRunPreflights(); initObservatory(); });
})();

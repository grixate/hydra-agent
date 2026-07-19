const palette = ["#567a68", "#8b7656", "#6d7894", "#9b6d65", "#687b85", "#8b748a"]
const zoomModes = ["density", "cohorts", "samples"]
const labelTranslations = {
  ru: {
    participant: "Участники",
    decision_maker: "Лица, принимающие решения",
    influencer: "Лидеры мнений",
    influence: "Влияние",
    information: "Информация",
    time: "Время",
    trust: "Доверие",
    last_action: "Последнее действие",
    phase: "Состояние",
    uncommitted: "Без решения",
    adopt: "Принять",
    delay: "Отложить",
    resist: "Отказаться",
    influence_others: "Повлиять на других",
    model: "Модель",
    rule: "Правило",
    original: "Исходный запуск",
    exact_replay: "Точный повтор",
    fresh_rerun: "Новый запуск",
    signature_reuse: "Повтор по сигнатуре",
    recorded_decision: "Записанное решение",
    incoming: "Входящая",
    outgoing: "Исходящая",
    undirected: "Ненаправленная",
    claim: "Утверждение",
    assumption: "Допущение",
    primary_action_rate: "Доля основного действия"
  }
}
const compactCanvasTranslations = {
  ru: {participant: "Участники", decision_maker: "ЛПР", influencer: "Лидеры мнений"},
  en: {participant: "participant", decision_maker: "decision maker", influencer: "influencer"}
}

const clamp = (value, minimum, maximum) => Math.max(minimum, Math.min(maximum, value))

const compactNumber = value => {
  const number = Number(value)
  if (!Number.isFinite(number)) return "—"
  return new Intl.NumberFormat(document.documentElement.lang || "en", {maximumFractionDigits: 2}).format(number)
}

const humanize = (value, locale = document.documentElement.lang || "en") => {
  const raw = String(value || "—").replace(/^agent_type:/, "")
  return labelTranslations[locale]?.[raw] || raw.replaceAll("_", " ")
}

const canvasLabel = (value, locale) => compactCanvasTranslations[locale]?.[value] || humanize(value, locale)

function wrappedCanvasLines(context, value, maxWidth, maxLines = 3) {
  const words = String(value).split(/\s+/).filter(Boolean)
  const lines = []

  words.forEach(word => {
    const current = lines[lines.length - 1]
    if (!current || context.measureText(`${current} ${word}`).width > maxWidth) lines.push(word)
    else lines[lines.length - 1] = `${current} ${word}`
  })

  if (lines.length <= maxLines) return lines
  return lines.slice(0, maxLines - 1).concat(lines.slice(maxLines - 1).join(" "))
}

function element(tag, text, className) {
  const node = document.createElement(tag)
  if (text !== undefined && text !== null) node.textContent = text
  if (className) node.className = className
  return node
}

function initLensNavigation(root, redraw) {
  const navigation = root.querySelector(".simulation-observatory-lenses")
  const links = Array.from(root.querySelectorAll("[data-observatory-lens]"))
  const panels = Array.from(root.querySelectorAll("[data-observatory-panel]"))
  if (!navigation || links.length === 0 || panels.length === 0) return

  navigation.setAttribute("role", "tablist")

  const activate = (lens, focus = false) => {
    links.forEach(link => {
      const active = link.dataset.observatoryLens === lens
      link.setAttribute("role", "tab")
      link.setAttribute("aria-selected", String(active))
      link.setAttribute("aria-current", active ? "page" : "false")
      link.tabIndex = active ? 0 : -1
      if (active && focus) link.focus()
    })

    panels.forEach(panel => {
      const active = panel.dataset.observatoryPanel === lens
      panel.setAttribute("role", "tabpanel")
      panel.hidden = !active
    })

    redraw(lens)
  }

  links.forEach((link, index) => {
    const panel = panels.find(item => item.dataset.observatoryPanel === link.dataset.observatoryLens)
    link.id = `observatory-tab-${link.dataset.observatoryLens}`
    if (panel) {
      link.setAttribute("aria-controls", panel.id)
      panel.setAttribute("aria-labelledby", link.id)
    }

    link.addEventListener("click", event => {
      event.preventDefault()
      activate(link.dataset.observatoryLens)
    })

    link.addEventListener("keydown", event => {
      let target
      if (event.key === "ArrowRight" || event.key === "ArrowDown") target = links[(index + 1) % links.length]
      if (event.key === "ArrowLeft" || event.key === "ArrowUp") target = links[(index - 1 + links.length) % links.length]
      if (event.key === "Home") target = links[0]
      if (event.key === "End") target = links[links.length - 1]
      if (!target) return
      event.preventDefault()
      activate(target.dataset.observatoryLens, true)
    })
  })

  activate("state")
}

function canvasContext(canvas) {
  if (!canvas) return null
  const context = canvas.getContext("2d")
  if (!context) return null
  const rect = canvas.getBoundingClientRect()
  const ratio = Math.min(window.devicePixelRatio || 1, 2)
  const width = Math.max(Math.floor(rect.width), 320)
  const height = Math.max(Math.floor(rect.height), 260)
  if (canvas.width !== Math.floor(width * ratio) || canvas.height !== Math.floor(height * ratio)) {
    canvas.width = Math.floor(width * ratio)
    canvas.height = Math.floor(height * ratio)
  }
  context.setTransform(ratio, 0, 0, ratio, 0, 0)
  return {context, width, height}
}

function drawGrid(context, width, height) {
  context.clearRect(0, 0, width, height)
  context.fillStyle = "#fbfbf8"
  context.fillRect(0, 0, width, height)
  context.strokeStyle = "rgba(39, 50, 44, .055)"
  context.lineWidth = 1
  for (let x = 0; x <= width; x += 48) {
    context.beginPath()
    context.moveTo(x, 0)
    context.lineTo(x, height)
    context.stroke()
  }
  for (let y = 0; y <= height; y += 48) {
    context.beginPath()
    context.moveTo(0, y)
    context.lineTo(width, y)
    context.stroke()
  }
}

function stateRenderer(root, payload, selectAgent) {
  const canvas = root.querySelector("[data-observatory-state-canvas]")
  const zoomOut = root.querySelector("[data-observatory-zoom-out]")
  const zoomIn = root.querySelector("[data-observatory-zoom-in]")
  const zoomLabel = root.querySelector("[data-observatory-zoom-label]")
  if (!canvas) return {draw: () => {}}

  const cohorts = (payload.state?.cohorts || []).filter(cohort => cohort.kind === "type")
  const samples = payload.state?.samples || []
  let zoomIndex = 1
  let selectedIndex = 0
  let samplePoints = []
  const locale = root.dataset.locale || "en"

  const colorFor = id => palette[Math.abs(String(id).split("").reduce((sum, char) => sum + char.charCodeAt(0), 0)) % palette.length]

  const drawDensity = (context, width, height) => {
    cohorts.forEach(cohort => {
      const x = .12 * width + Number(cohort.x || .5) * .76 * width
      const y = .12 * height + Number(cohort.y || .5) * .76 * height
      const radius = 34 + Math.sqrt(Math.max(Number(cohort.share || 0), .02)) * Math.min(width, height) * .2
      const gradient = context.createRadialGradient(x, y, 4, x, y, radius)
      const color = colorFor(cohort.id)
      gradient.addColorStop(0, `${color}a6`)
      gradient.addColorStop(.52, `${color}38`)
      gradient.addColorStop(1, `${color}00`)
      context.fillStyle = gradient
      context.beginPath()
      context.arc(x, y, radius, 0, Math.PI * 2)
      context.fill()
    })
  }

  const drawCohorts = (context, width, height) => {
    cohorts.forEach(cohort => {
      const x = .12 * width + Number(cohort.x || .5) * .76 * width
      const y = .12 * height + Number(cohort.y || .5) * .76 * height
      const radius = 28 + Math.sqrt(Math.max(Number(cohort.share || 0), .02)) * Math.min(width, height) * .13
      const color = colorFor(cohort.id)

      if (cohort.baseline_share !== undefined) {
        const baselineRadius = 28 + Math.sqrt(Math.max(Number(cohort.baseline_share || 0), .02)) * Math.min(width, height) * .13
        context.save()
        context.strokeStyle = "#858982"
        context.setLineDash([5, 5])
        context.lineWidth = 1.5
        context.beginPath()
        context.arc(x, y, baselineRadius, 0, Math.PI * 2)
        context.stroke()
        context.restore()
      }

      context.fillStyle = `${color}d9`
      context.beginPath()
      context.arc(x, y, radius, 0, Math.PI * 2)
      context.fill()
      context.fillStyle = "#ffffff"
      context.font = "600 12px ui-sans-serif, system-ui, sans-serif"
      context.textAlign = "center"
      const lines = wrappedCanvasLines(context, humanize(cohort.id, locale), radius * 1.45)
      const lineHeight = 13
      const firstLineY = y - ((lines.length - 1) * lineHeight) / 2 - 6
      lines.forEach((line, index) => context.fillText(line, x, firstLineY + index * lineHeight))
      context.font = "11px ui-monospace, monospace"
      context.fillText(compactNumber(cohort.count), x, firstLineY + lines.length * lineHeight + 5)
    })
  }

  const drawSamples = (context, width, height) => {
    samplePoints = samples.map((sample, index) => {
      const x = .08 * width + Number(sample.x || .5) * .84 * width
      const y = .1 * height + Number(sample.y || .5) * .8 * height
      const selected = index === selectedIndex
      context.fillStyle = colorFor(sample.type)
      context.beginPath()
      context.arc(x, y, selected ? 7 : 4.5, 0, Math.PI * 2)
      context.fill()
      if (selected) {
        context.strokeStyle = "#18261f"
        context.lineWidth = 2
        context.beginPath()
        context.arc(x, y, 11, 0, Math.PI * 2)
        context.stroke()
        context.fillStyle = "#26352d"
        context.font = "600 12px ui-sans-serif, system-ui, sans-serif"
        context.textAlign = "left"
        const label = `${canvasLabel(sample.type, locale)} · ${String(sample.id).replace("agent-", "").slice(0, 8)}`
        const alignRight = x > width * .62
        context.textAlign = alignRight ? "right" : "left"
        context.fillText(label, x + (alignRight ? -16 : 16), y + 4)
      }
      return {x, y, sample}
    })
  }

  const draw = () => {
    const frame = canvasContext(canvas)
    if (!frame) return
    drawGrid(frame.context, frame.width, frame.height)
    if (zoomModes[zoomIndex] === "density") drawDensity(frame.context, frame.width, frame.height)
    if (zoomModes[zoomIndex] === "cohorts") drawCohorts(frame.context, frame.width, frame.height)
    if (zoomModes[zoomIndex] === "samples") drawSamples(frame.context, frame.width, frame.height)
  }

  const updateZoom = next => {
    zoomIndex = clamp(next, 0, zoomModes.length - 1)
    const mode = zoomModes[zoomIndex]
    zoomLabel.textContent = root.dataset[`copyZoom${mode[0].toUpperCase()}${mode.slice(1)}`] || humanize(mode, locale)
    zoomOut.disabled = zoomIndex === 0
    zoomIn.disabled = zoomIndex === zoomModes.length - 1
    draw()
  }

  zoomOut?.addEventListener("click", () => updateZoom(zoomIndex - 1))
  zoomIn?.addEventListener("click", () => updateZoom(zoomIndex + 1))

  canvas.addEventListener("click", event => {
    if (zoomModes[zoomIndex] !== "samples" || samplePoints.length === 0) return
    const rect = canvas.getBoundingClientRect()
    const x = event.clientX - rect.left
    const y = event.clientY - rect.top
    const nearest = samplePoints
      .map((point, index) => ({index, distance: Math.hypot(point.x - x, point.y - y)}))
      .sort((a, b) => a.distance - b.distance)[0]
    if (!nearest || nearest.distance > 28) return
    selectedIndex = nearest.index
    draw()
    selectAgent(samples[selectedIndex].id)
  })

  canvas.addEventListener("keydown", event => {
    if (samples.length === 0) return
    if (event.key === "ArrowRight" || event.key === "ArrowDown") selectedIndex = (selectedIndex + 1) % samples.length
    else if (event.key === "ArrowLeft" || event.key === "ArrowUp") selectedIndex = (selectedIndex - 1 + samples.length) % samples.length
    else if (event.key === "Home") selectedIndex = 0
    else if (event.key === "End") selectedIndex = samples.length - 1
    else if (event.key === "Enter" || event.key === " ") {
      event.preventDefault()
      selectAgent(samples[selectedIndex].id)
      return
    } else return
    event.preventDefault()
    if (zoomIndex !== 2) updateZoom(2)
    else draw()
  })

  updateZoom(1)
  return {draw}
}

function lineSeries(context, points, color, dashed = false) {
  if (points.length === 0) return
  context.save()
  context.strokeStyle = color
  context.lineWidth = dashed ? 1.5 : 2.5
  if (dashed) context.setLineDash([6, 5])
  context.beginPath()
  points.forEach((point, index) => index === 0 ? context.moveTo(point.x, point.y) : context.lineTo(point.x, point.y))
  context.stroke()
  context.restore()
}

function flowRenderer(root, payload) {
  const canvas = root.querySelector("[data-observatory-flow-canvas]")
  const input = root.querySelector("[data-observatory-round]")
  const output = root.querySelector("[data-observatory-round-output]")
  if (!canvas) return {draw: () => {}}

  const metric = payload.flow?.metric_ids?.[0]
  const timeline = payload.flow?.timeline || []
  const baseline = payload.flow?.baseline_timeline || []
  let selectedRound = Number(input?.value || payload.run?.rounds || 1)
  const locale = root.dataset.locale || "en"

  const draw = () => {
    const frame = canvasContext(canvas)
    if (!frame) return
    const {context, width, height} = frame
    drawGrid(context, width, height)
    const plot = {left: 62, right: width - 24, top: 42, bottom: height - 48}
    const currentValues = timeline.map(point => Number(point.metrics?.[metric])).filter(Number.isFinite)
    const baselineValues = baseline.map(point => Number(point.metrics?.[metric])).filter(Number.isFinite)
    const values = currentValues.concat(baselineValues)
    const minimum = values.length ? Math.min(...values) : 0
    const maximum = values.length ? Math.max(...values) : 1
    const spread = Math.max(maximum - minimum, .000001)
    const rounds = Math.max(Number(payload.run?.rounds || 1), 1)
    const point = item => ({
      x: plot.left + ((Number(item.round) - 1) / Math.max(rounds - 1, 1)) * (plot.right - plot.left),
      y: plot.bottom - ((Number(item.metrics?.[metric]) - minimum) / spread) * (plot.bottom - plot.top)
    })
    const currentPoints = timeline.filter(item => Number.isFinite(Number(item.metrics?.[metric]))).map(point)
    const baselinePoints = baseline.filter(item => Number.isFinite(Number(item.metrics?.[metric]))).map(point)

    context.strokeStyle = "#9da49f"
    context.lineWidth = 1
    context.beginPath()
    context.moveTo(plot.left, plot.top)
    context.lineTo(plot.left, plot.bottom)
    context.lineTo(plot.right, plot.bottom)
    context.stroke()

    lineSeries(context, baselinePoints, "#8a8f8a", true)
    lineSeries(context, currentPoints, "#567a68")

    const markerX = plot.left + ((selectedRound - 1) / Math.max(rounds - 1, 1)) * (plot.right - plot.left)
    context.strokeStyle = "rgba(39, 50, 44, .5)"
    context.setLineDash([2, 4])
    context.beginPath()
    context.moveTo(markerX, plot.top)
    context.lineTo(markerX, plot.bottom)
    context.stroke()
    context.setLineDash([])

    context.fillStyle = "#26352d"
    context.font = "600 13px ui-sans-serif, system-ui, sans-serif"
    context.textAlign = "left"
    context.fillText(humanize(metric || "recorded metric", locale), plot.left, 23)
    context.font = "11px ui-monospace, monospace"
    context.fillText(compactNumber(maximum), 8, plot.top + 4)
    context.fillText(compactNumber(minimum), 8, plot.bottom + 4)
    context.textAlign = "center"
    context.fillText("1", plot.left, height - 18)
    context.fillText(String(rounds), plot.right, height - 18)
  }

  const setRound = round => {
    selectedRound = clamp(Number(round), 1, Number(payload.run?.rounds || 1))
    if (input) input.value = String(selectedRound)
    if (output) output.textContent = String(selectedRound)
    draw()
  }

  input?.addEventListener("input", event => setRound(event.target.value))
  input?.addEventListener("keydown", event => {
    if (event.key === "Home") setRound(1)
    else if (event.key === "End") setRound(payload.run?.rounds || 1)
    else if (event.key === "ArrowLeft" || event.key === "ArrowDown") setRound(selectedRound - 1)
    else if (event.key === "ArrowRight" || event.key === "ArrowUp") setRound(selectedRound + 1)
    else return
    event.preventDefault()
  })
  canvas.addEventListener("keydown", event => {
    if (event.key === "ArrowLeft" || event.key === "ArrowDown") setRound(selectedRound - 1)
    else if (event.key === "ArrowRight" || event.key === "ArrowUp") setRound(selectedRound + 1)
    else if (event.key === "Home") setRound(1)
    else if (event.key === "End") setRound(payload.run?.rounds || 1)
    else return
    event.preventDefault()
  })

  draw()
  return {draw}
}

function addDefinitionList(parent, title, values, locale) {
  if (!values || typeof values !== "object" || Array.isArray(values) || Object.keys(values).length === 0) return
  const section = element("section", undefined, "simulation-agent-detail-section")
  section.append(element("h5", title))
  const list = element("dl")
  Object.entries(values).slice(0, 20).forEach(([key, value]) => {
    const row = element("div")
    row.append(element("dt", humanize(key, locale)), element("dd", typeof value === "object" ? JSON.stringify(value) : compactNumber(value) === "—" ? String(value) : compactNumber(value)))
    list.append(row)
  })
  section.append(list)
  parent.append(section)
}

function addList(parent, title, values) {
  if (!Array.isArray(values) || values.length === 0) return
  const section = element("section", undefined, "simulation-agent-detail-section")
  section.append(element("h5", title))
  const list = element("ul")
  values.slice(0, 24).forEach(value => list.append(element("li", typeof value === "object" ? JSON.stringify(value) : value)))
  section.append(list)
  parent.append(section)
}

function renderAgentDetail(root, detail) {
  const inspector = root.querySelector("[data-observatory-inspector]")
  const title = root.querySelector("[data-observatory-inspector-title]")
  const content = root.querySelector("[data-observatory-inspector-content]")
  if (!inspector || !title || !content) return

  const locale = root.dataset.locale || "en"
  const copy = key => root.dataset[`copy${key[0].toUpperCase()}${key.slice(1)}`] || humanize(key, locale)
  const agent = detail.agent || {}
  title.textContent = `${humanize(agent.type, locale)} · ${String(agent.id || "").replace("agent-", "").slice(0, 10)}`
  content.replaceChildren()
  content.append(element("p", root.dataset.copySynthetic, "simulation-agent-synthetic-note"))

  if (detail.persona?.prose) {
    const persona = element("section", undefined, "simulation-agent-persona")
    persona.append(element("h5", copy("persona")), element("p", detail.persona.prose))
    content.append(persona)
  }

  const grids = element("div", undefined, "simulation-agent-detail-grid")
  addDefinitionList(grids, copy("currentState"), agent.state, locale)
  addDefinitionList(grids, copy("resources"), agent.resources, locale)
  addDefinitionList(grids, copy("attributes"), agent.attributes, locale)
  content.append(grids)

  const lists = element("div", undefined, "simulation-agent-detail-grid")
  addList(lists, copy("goals"), agent.goals)
  addList(lists, copy("constraints"), agent.constraints)
  content.append(lists)

  if (Array.isArray(detail.history) && detail.history.length) {
    const section = element("section", undefined, "simulation-agent-history simulation-agent-detail-section")
    section.append(element("h5", copy("history")))
    const tableWrap = element("div", undefined, "simulation-observatory-table-scroll")
    tableWrap.tabIndex = 0
    const table = element("table")
    const head = element("thead")
    const headRow = element("tr")
    ;[copy("round"), copy("action"), copy("state"), copy("resources")].forEach(label => headRow.append(element("th", label)))
    head.append(headRow)
    const body = element("tbody")
    detail.history.forEach(row => {
      const tr = element("tr")
      tr.append(element("th", row.round), element("td", humanize(row.action, locale)), element("td", Object.entries(row.state || {}).map(([key, value]) => `${humanize(key, locale)}: ${humanize(value, locale)}`).join(" · ") || "—"), element("td", Object.entries(row.resources || {}).map(([key, value]) => `${humanize(key, locale)}: ${value}`).join(" · ") || "—"))
      body.append(tr)
    })
    table.append(head, body)
    tableWrap.append(table)
    section.append(tableWrap)
    content.append(section)
  }

  if (Array.isArray(detail.decisions) && detail.decisions.length) {
    const section = element("section", undefined, "simulation-agent-decisions simulation-agent-detail-section")
    section.append(element("h5", copy("decisions")))
    const list = element("ol")
    detail.decisions.forEach(decision => {
      const item = element("li")
      const heading = element("strong", `${copy("round")} ${decision.round} · ${humanize(decision.action_id, locale)}`)
      const meta = element("small", `${humanize(decision.source, locale)} · ${humanize(decision.reuse_kind, locale)} · ${compactNumber(decision.affected_agent_count)} ${copy("affected")}`)
      item.append(heading, meta)
      if (decision.short_rationale) item.append(element("p", decision.short_rationale))
      if (decision.perceived_context && Object.keys(decision.perceived_context).length) {
        const details = element("details")
        details.append(element("summary", copy("perceivedContext")), element("pre", JSON.stringify(decision.perceived_context, null, 2)))
        item.append(details)
      }
      list.append(item)
    })
    section.append(list)
    content.append(section)
  }

  if (Array.isArray(detail.relationships) && detail.relationships.length) {
    const section = element("section", undefined, "simulation-agent-detail-section")
    section.append(element("h5", copy("relationships")))
    const list = element("ul")
    detail.relationships.forEach(relationship => list.append(element("li", `${humanize(relationship.type, locale)} · ${humanize(relationship.direction, locale)} · ${String(relationship.other_agent_id).replace("agent-", "").slice(0, 10)} · ${compactNumber(relationship.weight)}`)))
    section.append(list)
    content.append(section)
  }

  if (Array.isArray(detail.grounding) && detail.grounding.length) {
    const section = element("section", undefined, "simulation-agent-detail-section")
    section.append(element("h5", copy("grounding")))
    const list = element("ul")
    detail.grounding.forEach(item => list.append(element("li", `${humanize(item.kind, locale)} · ${item.statement || item.id}`)))
    section.append(list)
    content.append(section)
  }

  inspector.setAttribute("aria-busy", "false")
  title.focus({preventScroll: false})
}

function agentLoader(root) {
  const inspector = root.querySelector("[data-observatory-inspector]")
  const title = root.querySelector("[data-observatory-inspector-title]")
  const content = root.querySelector("[data-observatory-inspector-content]")
  let controller

  const load = async agentId => {
    if (!agentId || !inspector || !title || !content) return
    controller?.abort()
    controller = new AbortController()
    inspector.setAttribute("aria-busy", "true")
    title.textContent = root.dataset.copyAgentLoading
    content.replaceChildren(element("p", root.dataset.copyAgentLoading))
    root.querySelectorAll("[data-observatory-agent]").forEach(button => button.setAttribute("aria-pressed", String(button.dataset.observatoryAgent === agentId)))

    try {
      const url = root.dataset.agentUrlBase.replace("__agent__", encodeURIComponent(agentId))
      const response = await fetch(url, {headers: {accept: "application/json"}, credentials: "same-origin", signal: controller.signal})
      if (!response.ok) throw new Error(`agent detail ${response.status}`)
      renderAgentDetail(root, await response.json())
    } catch (error) {
      if (error.name === "AbortError") return
      inspector.setAttribute("aria-busy", "false")
      title.textContent = root.dataset.copyAgentError
      content.replaceChildren(element("p", root.dataset.copyAgentError))
    }
  }

  root.querySelectorAll("[data-observatory-agent]").forEach(button => button.addEventListener("click", () => load(button.dataset.observatoryAgent)))
  return load
}

async function initObservatory(root) {
  if (root.dataset.observatoryInitialized === "true") return
  root.dataset.observatoryInitialized = "true"
  const status = root.querySelector("[data-observatory-visual-status]")
  const loadAgent = agentLoader(root)
  let state = {draw: () => {}}
  let flow = {draw: () => {}}

  initLensNavigation(root, lens => {
    if (lens === "state") state.draw()
    if (lens === "flow") flow.draw()
  })

  try {
    const response = await fetch(root.dataset.payloadUrl, {headers: {accept: "application/json"}, credentials: "same-origin"})
    if (!response.ok) throw new Error(`observatory ${response.status}`)
    const payload = await response.json()
    state = stateRenderer(root, payload, loadAgent)
    flow = flowRenderer(root, payload)
    if (status) status.hidden = true

    if (window.ResizeObserver) {
      const observer = new ResizeObserver(() => {
        state.draw()
        flow.draw()
      })
      root.querySelectorAll("canvas").forEach(canvas => observer.observe(canvas))
    } else {
      window.addEventListener("resize", () => {
        state.draw()
        flow.draw()
      }, {passive: true})
    }
  } catch (_error) {
    if (status) status.textContent = root.dataset.copyError
    root.dataset.observatoryFailed = "true"
  }
}

export function initObservatories() {
  document.querySelectorAll("[data-observatory]").forEach(initObservatory)
}

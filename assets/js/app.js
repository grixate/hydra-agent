import "phoenix_html"
import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"

const bootstrapPreferences = () => {
  const density = localStorage.getItem("hydra-density") || "comfortable"

  document.documentElement.dataset.theme = "light"
  document.documentElement.dataset.density = density
}

bootstrapPreferences()

const applyPreferenceLabels = () => {
  const density = document.documentElement.dataset.density || "comfortable"

  document.querySelectorAll("[data-hx-density-toggle]").forEach((button) => {
    button.textContent = density === "compact" ? "Comfortable" : "Compact"
    button.setAttribute("aria-pressed", density === "compact" ? "true" : "false")
  })
}

const setDensity = (density) => {
  document.documentElement.dataset.density = density
  localStorage.setItem("hydra-density", density)
  applyPreferenceLabels()
}

const openCommandPalette = () => {
  const palette = document.getElementById("hx-command-palette")
  const input = document.getElementById("hx-command-input")
  if (!palette) return
  palette.hidden = false
  input?.focus()
}

const closeCommandPalette = () => {
  document.getElementById("hx-command-palette")?.setAttribute("hidden", "")
}

document.addEventListener("click", (event) => {
  const target = event.target.closest("button, [data-hx-command-close]")
  if (!target) return

  if (target.matches("[data-hx-density-toggle]")) {
    const next = document.documentElement.dataset.density === "compact" ? "comfortable" : "compact"
    setDensity(next)
  }

  if (target.matches("[data-hx-command-open]")) {
    openCommandPalette()
  }

  if (target.matches("[data-hx-command-close]")) {
    closeCommandPalette()
  }
})

document.addEventListener("keydown", (event) => {
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
    event.preventDefault()
    openCommandPalette()
  }

  if (event.key === "Escape") {
    closeCommandPalette()
  }
})

window.addEventListener("DOMContentLoaded", applyPreferenceLabels)

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

let liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken }
})

liveSocket.connect()
window.liveSocket = liveSocket

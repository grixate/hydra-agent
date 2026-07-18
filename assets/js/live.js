import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken}
})

window.addEventListener("phx:page-loading-start", () => {
  document.documentElement.classList.add("is-page-loading")
})

window.addEventListener("phx:page-loading-stop", () => {
  document.documentElement.classList.remove("is-page-loading")
})

document.addEventListener("click", event => {
  const restore = event.target.closest("[data-blueprint-restore]")

  if (restore) {
    const module = restore.dataset.blueprintRestore
    const target = document.getElementById(restore.dataset.blueprintTarget)
    const source = document.getElementById(`blueprint-default-${module}`)

    if (target && source) {
      target.value = source.content.textContent.trim()
      target.dispatchEvent(new Event("input", {bubbles: true}))
      target.focus()

      const announcer = document.querySelector("[data-blueprint-announcer]")
      if (announcer) announcer.textContent = restore.dataset.blueprintMessage || ""
    }
  }

  const sampleButton = event.target.closest("[data-blueprint-sample]")

  if (sampleButton) {
    const sample = document.getElementById(sampleButton.dataset.blueprintSample)

    if (sample) {
      sample.hidden = !sample.hidden
      sampleButton.setAttribute("aria-expanded", String(!sample.hidden))
    }
  }
})

document.addEventListener("change", event => {
  if (!event.target.matches("[data-blueprint-file]")) return

  const filename = event.target.closest("form")?.querySelector("[data-blueprint-filename]")
  if (filename) filename.textContent = event.target.files?.[0]?.name || filename.textContent
})

liveSocket.connect()
window.liveSocket = liveSocket

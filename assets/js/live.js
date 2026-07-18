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

liveSocket.connect()
window.liveSocket = liveSocket

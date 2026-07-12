import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

export default class extends Controller {
  static targets = ["error"]
  static values = {
    active: Boolean,
    url: String,
    version: String,
  }

  connect() {
    this.schedule()
  }

  disconnect() {
    window.clearTimeout(this.timer)
  }

  schedule(delay = 2000) {
    if (!this.activeValue) return
    window.clearTimeout(this.timer)
    this.timer = window.setTimeout(() => this.refresh(), delay)
  }

  async refresh() {
    if (document.hidden) {
      this.schedule(5000)
      return
    }

    this.element.setAttribute("aria-busy", "true")
    try {
      const response = await fetch(this.urlValue, {
        cache: "no-store",
        credentials: "same-origin",
        headers: {
          Accept: "text/vnd.turbo-stream.html",
          "X-Lrail-Live-Version": this.versionValue,
        },
      })

      if (response.status === 304) {
        this.element.setAttribute("aria-busy", "false")
        this.errorTarget.hidden = true
        this.schedule()
        return
      }
      if (!response.ok || !response.headers.get("Content-Type")?.includes("text/vnd.turbo-stream.html")) {
        throw new Error("live status request failed")
      }

      Turbo.renderStreamMessage(await response.text())
    } catch (_error) {
      this.element.setAttribute("aria-busy", "false")
      this.errorTarget.hidden = false
      this.schedule(5000)
    }
  }
}

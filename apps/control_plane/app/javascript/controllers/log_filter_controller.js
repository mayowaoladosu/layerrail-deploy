import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["empty", "entry", "query", "stream"]
  static values = { storageKey: String }

  connect() {
    const saved = this.readState()
    this.queryTarget.value = saved.query || ""
    this.streamTarget.value = saved.stream || "all"
    this.filter()
  }

  filter() {
    const query = this.queryTarget.value.trim().toLowerCase()
    const stream = this.streamTarget.value
    let visible = 0

    this.entryTargets.forEach((entry) => {
      const matchesStream = stream === "all" || entry.dataset.stream === stream
      const matchesQuery = !query || entry.dataset.message.includes(query)
      entry.hidden = !(matchesStream && matchesQuery)
      if (!entry.hidden) visible += 1
    })

    this.emptyTarget.hidden = visible !== 0
    this.writeState({ query, stream })
  }

  readState() {
    try {
      return JSON.parse(window.sessionStorage.getItem(this.storageKeyValue) || "{}")
    } catch (_error) {
      return {}
    }
  }

  writeState(value) {
    try {
      window.sessionStorage.setItem(this.storageKeyValue, JSON.stringify(value))
    } catch (_error) {
      // Filtering remains functional when browser storage is unavailable.
    }
  }
}

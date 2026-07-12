import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["button", "spinner"]

  start() {
    this.buttonTargets.forEach((button) => {
      button.disabled = true
      button.setAttribute("aria-busy", "true")
    })
    this.spinnerTargets.forEach((spinner) => {
      spinner.hidden = false
    })
  }
}

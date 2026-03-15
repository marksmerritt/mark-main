import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    // Slide in
    requestAnimationFrame(() => {
      this.element.classList.add("toast-visible")
    })

    // Auto-dismiss after 4 seconds
    this.timeout = setTimeout(() => this.dismiss(), 4000)
  }

  disconnect() {
    if (this.timeout) clearTimeout(this.timeout)
  }

  dismiss() {
    this.element.classList.remove("toast-visible")
    this.element.classList.add("toast-hiding")
    setTimeout(() => this.element.remove(), 300)
  }
}

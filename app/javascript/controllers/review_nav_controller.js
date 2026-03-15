import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { prevUrl: String, nextUrl: String }

  connect() {
    this.handleKey = this.handleKey.bind(this)
    document.addEventListener("keydown", this.handleKey)
  }

  disconnect() {
    document.removeEventListener("keydown", this.handleKey)
  }

  handleKey(event) {
    // Don't navigate if user is typing in an input
    if (event.target.tagName === "INPUT" || event.target.tagName === "TEXTAREA" || event.target.tagName === "SELECT") return

    if (event.key === "ArrowLeft" || event.key === "k") {
      if (this.prevUrlValue) {
        event.preventDefault()
        window.location.href = this.prevUrlValue
      }
    } else if (event.key === "ArrowRight" || event.key === "j") {
      if (this.nextUrlValue) {
        event.preventDefault()
        window.location.href = this.nextUrlValue
      }
    }
  }
}

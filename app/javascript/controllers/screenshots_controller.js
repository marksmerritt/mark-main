import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["form", "filename", "caption"]
  static values = { tradeId: Number, csrf: String }

  toggleForm() {
    this.formTarget.classList.toggle("hidden")
    if (!this.formTarget.classList.contains("hidden")) {
      this.filenameTarget.focus()
    }
  }

  async add() {
    const filename = this.filenameTarget.value.trim()
    if (!filename) {
      alert("Filename is required.")
      return
    }

    const ext = filename.split(".").pop().toLowerCase()
    const contentTypes = { png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", gif: "image/gif", webp: "image/webp" }
    const contentType = contentTypes[ext] || "image/png"

    try {
      const response = await fetch(`/trades/${this.tradeIdValue}/screenshots`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrfValue
        },
        body: JSON.stringify({
          trade_screenshot: {
            filename: filename,
            content_type: contentType,
            caption: this.captionTarget.value.trim()
          }
        })
      })

      if (response.ok) {
        window.location.reload()
      } else {
        const data = await response.json()
        alert(data.errors ? data.errors.join(", ") : "Failed to add screenshot.")
      }
    } catch (e) {
      alert("Failed to add screenshot.")
    }
  }
}

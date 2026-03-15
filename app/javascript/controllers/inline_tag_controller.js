import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["display", "editor", "checkbox"]
  static values = { url: String, csrfToken: String }

  toggleEditor() {
    this.editorTarget.classList.toggle("hidden")
  }

  async save() {
    const selectedIds = this.checkboxTargets
      .filter(cb => cb.checked)
      .map(cb => cb.value)

    try {
      const response = await fetch(this.urlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrfTokenValue,
          "Accept": "text/html"
        },
        body: JSON.stringify({ trade: { tag_ids: selectedIds } })
      })

      if (response.ok || response.redirected) {
        window.location.reload()
      }
    } catch (error) {
      console.error("Failed to update tags:", error)
    }
  }
}

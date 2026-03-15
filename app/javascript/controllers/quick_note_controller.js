import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["form", "textarea", "display", "trigger"]
  static values = { url: String, csrfToken: String }

  show() {
    this.formTarget.classList.remove("hidden")
    this.triggerTarget.classList.add("hidden")
    this.textareaTarget.focus()
  }

  cancel() {
    this.formTarget.classList.add("hidden")
    this.triggerTarget.classList.remove("hidden")
    this.textareaTarget.value = ""
  }

  async save() {
    const note = this.textareaTarget.value.trim()
    if (!note) return

    const existing = this.displayTarget.dataset.currentNotes || ""
    const updatedNotes = existing ? `${existing}\n\n---\n${note}` : note

    try {
      const response = await fetch(this.urlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrfTokenValue
        },
        body: JSON.stringify({ trade: { notes: updatedNotes } })
      })

      if (response.ok) {
        // Update the display
        this.displayTarget.dataset.currentNotes = updatedNotes
        const displayContent = this.displayTarget.querySelector(".text-content")
        if (displayContent) {
          displayContent.innerHTML = updatedNotes.replace(/\n/g, "<br>")
        }
        this.textareaTarget.value = ""
        this.cancel()
        window.location.reload()
      } else {
        alert("Failed to save note.")
      }
    } catch (e) {
      alert("Failed to save note.")
    }
  }
}

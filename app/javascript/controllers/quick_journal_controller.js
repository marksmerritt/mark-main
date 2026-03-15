import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["modal", "content", "mood"]

  open() {
    this.modalTarget.classList.remove("hidden")
    this.contentTarget.focus()
  }

  close() {
    this.modalTarget.classList.add("hidden")
  }

  async submit(event) {
    event.preventDefault()
    const form = event.target
    const formData = new FormData(form)
    const body = {}
    formData.forEach((value, key) => {
      if (key !== "authenticity_token") body[key] = value
    })

    try {
      const response = await fetch(form.action, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": formData.get("authenticity_token"),
          "Accept": "application/json"
        },
        body: JSON.stringify(body)
      })

      if (response.ok || response.redirected) {
        this.close()
        // Show success toast
        const toast = document.createElement("div")
        toast.className = "toast toast-notice"
        toast.textContent = "Journal entry saved!"
        toast.style.cursor = "pointer"
        toast.addEventListener("click", () => toast.remove())
        document.querySelector(".toast-container")?.appendChild(toast)
        setTimeout(() => toast.remove(), 3000)
        // Reset form
        this.contentTarget.value = ""
        this.moodTargets.forEach(r => r.checked = false)
      } else {
        window.location.href = "/journal_entries/new"
      }
    } catch {
      window.location.href = "/journal_entries/new"
    }
  }
}

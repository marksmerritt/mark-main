import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["modal", "title", "content"]

  open() {
    this.modalTarget.classList.remove("hidden")
    requestAnimationFrame(() => this.titleTarget.focus())
  }

  close() {
    this.modalTarget.classList.add("hidden")
    this.titleTarget.value = ""
    this.contentTarget.value = ""
  }

  submit(event) {
    event.preventDefault()
    const form = event.target
    const formData = new FormData(form)

    fetch(form.action, {
      method: "POST",
      body: formData,
      headers: {
        "X-CSRF-Token": document.querySelector("meta[name='csrf-token']").content,
        "Accept": "text/html"
      }
    }).then(response => {
      if (response.redirected) {
        window.Turbo.visit(response.url)
      } else {
        this.close()
        window.Turbo.visit(window.location.href)
      }
    })
  }
}

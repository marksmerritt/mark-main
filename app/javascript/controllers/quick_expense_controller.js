import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["modal"]

  connect() {
    this.handleKey = this.handleKey.bind(this)
    document.addEventListener("keydown", this.handleKey)
  }

  disconnect() {
    document.removeEventListener("keydown", this.handleKey)
  }

  handleKey(event) {
    const tag = event.target.tagName.toLowerCase()
    if (tag === "input" || tag === "textarea" || tag === "select" || event.target.isContentEditable) return
    if (event.ctrlKey || event.metaKey || event.altKey) return

    if (event.key === "x") {
      event.preventDefault()
      this.open()
    }
  }

  open() {
    if (this.hasModalTarget && !this.modalTarget.classList.contains("hidden")) return
    this.modalTarget.classList.remove("hidden")
    const firstInput = this.modalTarget.querySelector("input[type='number']")
    if (firstInput) firstInput.focus()
  }

  close() {
    this.modalTarget.classList.add("hidden")
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
        form.reset()
        window.Turbo.visit(window.location.href)
      }
    })
  }
}

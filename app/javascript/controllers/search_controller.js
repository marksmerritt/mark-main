import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["form", "input", "loading"]

  connect() {
    this.timeout = null
  }

  disconnect() {
    if (this.timeout) clearTimeout(this.timeout)
  }

  input() {
    if (this.timeout) clearTimeout(this.timeout)

    this.timeout = setTimeout(() => {
      this.submit()
    }, 300)
  }

  submit() {
    if (this.hasLoadingTarget) {
      this.loadingTarget.classList.remove("hidden")
    }

    this.formTarget.requestSubmit()
  }
}

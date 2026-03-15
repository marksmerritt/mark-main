import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["links"]

  toggle() {
    this.linksTarget.classList.toggle("open")
  }

  close(event) {
    if (!this.element.contains(event.target)) {
      this.linksTarget.classList.remove("open")
    }
  }

  connect() {
    this.closeHandler = this.close.bind(this)
    document.addEventListener("click", this.closeHandler)
  }

  disconnect() {
    document.removeEventListener("click", this.closeHandler)
  }
}

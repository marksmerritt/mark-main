import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["button"]

  connect() {
    this.handleScroll = this.handleScroll.bind(this)
    window.addEventListener("scroll", this.handleScroll, { passive: true })
  }

  disconnect() {
    window.removeEventListener("scroll", this.handleScroll)
  }

  handleScroll() {
    if (window.scrollY > 400) {
      this.buttonTarget.classList.remove("hidden")
    } else {
      this.buttonTarget.classList.add("hidden")
    }
  }

  scrollToTop() {
    window.scrollTo({ top: 0, behavior: "smooth" })
  }
}

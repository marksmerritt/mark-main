import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["entries", "loading", "sentinel"]
  static values = {
    url: String,
    page: { type: Number, default: 1 },
    totalPages: { type: Number, default: 1 },
    loading: { type: Boolean, default: false }
  }

  connect() {
    this.observer = new IntersectionObserver(
      (entries) => { if (entries[0].isIntersecting) this.loadMore() },
      { rootMargin: "200px" }
    )
    if (this.hasSentinelTarget) {
      this.observer.observe(this.sentinelTarget)
    }
  }

  disconnect() {
    if (this.observer) this.observer.disconnect()
  }

  async loadMore() {
    if (this.loadingValue || this.pageValue >= this.totalPagesValue) return

    this.loadingValue = true
    this.loadingTarget.classList.remove("hidden")

    try {
      const nextPage = this.pageValue + 1
      const separator = this.urlValue.includes("?") ? "&" : "?"
      const response = await fetch(`${this.urlValue}${separator}page=${nextPage}`, {
        headers: { "Accept": "text/html" }
      })

      if (response.ok) {
        const html = await response.text()
        if (html.trim()) {
          this.entriesTarget.insertAdjacentHTML("beforeend", html)
          this.pageValue = nextPage
        }
      }
    } finally {
      this.loadingValue = false
      this.loadingTarget.classList.add("hidden")

      if (this.pageValue >= this.totalPagesValue) {
        this.sentinelTarget.classList.add("hidden")
        this.observer.disconnect()
      }
    }
  }
}

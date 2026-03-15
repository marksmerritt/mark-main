import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "list"]
  static values = { url: String, minLength: { type: Number, default: 2 } }

  connect() {
    this.handleInput = this.debounce(this.fetchResults.bind(this), 250)
    this.handleKeydown = this.handleKeydown.bind(this)
    this.handleClickOutside = this.handleClickOutside.bind(this)
    this.inputTarget.addEventListener("input", this.handleInput)
    this.inputTarget.addEventListener("keydown", this.handleKeydown)
    document.addEventListener("click", this.handleClickOutside)
    this.selectedIndex = -1
  }

  disconnect() {
    this.inputTarget.removeEventListener("input", this.handleInput)
    this.inputTarget.removeEventListener("keydown", this.handleKeydown)
    document.removeEventListener("click", this.handleClickOutside)
  }

  async fetchResults() {
    const query = this.inputTarget.value.trim()
    if (query.length < this.minLengthValue) { this.hide(); return }

    try {
      const url = `${this.urlValue}?q=${encodeURIComponent(query)}`
      const response = await fetch(url, {
        headers: { "Accept": "application/json" }
      })
      const results = await response.json()

      if (!Array.isArray(results) || results.length === 0) { this.hide(); return }

      this.selectedIndex = -1
      this.listTarget.innerHTML = results.map((item, i) =>
        `<div class="autocomplete-item" data-index="${i}" data-action="click->remote-autocomplete#select">${this.escapeHtml(item)}</div>`
      ).join("")
      this.listTarget.classList.remove("hidden")
    } catch {
      this.hide()
    }
  }

  handleKeydown(event) {
    const items = this.listTarget.querySelectorAll(".autocomplete-item")
    if (!items.length) return

    if (event.key === "ArrowDown") {
      event.preventDefault()
      this.selectedIndex = Math.min(this.selectedIndex + 1, items.length - 1)
      this.highlight(items)
    } else if (event.key === "ArrowUp") {
      event.preventDefault()
      this.selectedIndex = Math.max(this.selectedIndex - 1, 0)
      this.highlight(items)
    } else if (event.key === "Enter" && this.selectedIndex >= 0) {
      event.preventDefault()
      this.inputTarget.value = items[this.selectedIndex].textContent
      this.hide()
    } else if (event.key === "Escape") {
      this.hide()
    }
  }

  highlight(items) {
    items.forEach((item, i) => {
      item.classList.toggle("autocomplete-item-active", i === this.selectedIndex)
    })
  }

  select(event) {
    this.inputTarget.value = event.target.textContent
    this.hide()
  }

  hide() {
    this.listTarget.classList.add("hidden")
    this.listTarget.innerHTML = ""
  }

  handleClickOutside(event) {
    if (!this.element.contains(event.target)) this.hide()
  }

  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }

  debounce(fn, delay) {
    let timer
    return (...args) => {
      clearTimeout(timer)
      timer = setTimeout(() => fn(...args), delay)
    }
  }
}

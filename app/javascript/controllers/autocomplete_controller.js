import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "list"]
  static values = { items: Array }

  connect() {
    this.handleInput = this.handleInput.bind(this)
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

  handleInput() {
    const query = this.inputTarget.value.toUpperCase()
    if (query.length < 1) { this.hide(); return }

    const matches = this.itemsValue.filter(item =>
      item.toUpperCase().includes(query)
    ).slice(0, 8)

    if (matches.length === 0) { this.hide(); return }

    this.selectedIndex = -1
    this.listTarget.innerHTML = matches.map((item, i) =>
      `<div class="autocomplete-item" data-index="${i}" data-action="click->autocomplete#select">${item}</div>`
    ).join("")
    this.listTarget.classList.remove("hidden")
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
}

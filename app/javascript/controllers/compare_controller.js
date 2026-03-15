import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["checkbox", "bar", "count"]
  static values = { url: String }

  toggle() {
    this.updateBar()
  }

  toggleAll(event) {
    const checked = event.target.checked
    this.checkboxTargets.forEach(cb => cb.checked = checked)
    this.updateBar()
  }

  clear() {
    this.checkboxTargets.forEach(cb => cb.checked = false)
    this.updateBar()
  }

  go() {
    const ids = this.selectedIds()
    if (ids.length < 2) {
      alert("Select at least 2 trades to compare.")
      return
    }
    if (ids.length > 10) {
      alert("Select at most 10 trades to compare.")
      return
    }

    const params = ids.map(id => `trade_ids[]=${id}`).join("&")
    window.location.href = `${this.urlValue}?${params}`
  }

  updateBar() {
    const count = this.selectedIds().length
    this.countTarget.textContent = count

    if (count >= 2) {
      this.barTarget.classList.remove("hidden")
    } else {
      this.barTarget.classList.add("hidden")
    }
  }

  selectedIds() {
    return this.checkboxTargets.filter(cb => cb.checked).map(cb => cb.value)
  }
}

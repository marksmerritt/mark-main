import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["checkbox", "bar", "count", "tagSelect"]
  static values = {
    compareUrl: String,
    bulkTagUrl: String,
    bulkDeleteUrl: String,
    csrfToken: String
  }

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

  compare() {
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
    window.location.href = `${this.compareUrlValue}?${params}`
  }

  async bulkTag() {
    const ids = this.selectedIds()
    if (ids.length === 0) return

    if (!this.hasTagSelectTarget) return
    const tagIds = Array.from(this.tagSelectTarget.selectedOptions).map(o => o.value)
    if (tagIds.length === 0) {
      alert("Select at least one tag to apply.")
      return
    }

    try {
      const response = await fetch(this.bulkTagUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrfTokenValue
        },
        body: JSON.stringify({ trade_ids: ids, tag_ids: tagIds })
      })
      const result = await response.json()
      if (result.updated) {
        window.location.reload()
      } else {
        alert(result.error || "Failed to update trades.")
      }
    } catch (e) {
      alert("Failed to update trades.")
    }
  }

  async bulkDelete() {
    const ids = this.selectedIds()
    if (ids.length === 0) return

    if (!confirm(`Delete ${ids.length} trade(s)? This cannot be undone.`)) return

    try {
      const response = await fetch(this.bulkDeleteUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrfTokenValue
        },
        body: JSON.stringify({ trade_ids: ids })
      })
      const result = await response.json()
      if (result.deleted) {
        window.location.reload()
      } else {
        alert(result.error || "Failed to delete trades.")
      }
    } catch (e) {
      alert("Failed to delete trades.")
    }
  }

  updateBar() {
    const count = this.selectedIds().length
    this.countTarget.textContent = count

    if (count > 0) {
      this.barTarget.classList.remove("hidden")
    } else {
      this.barTarget.classList.add("hidden")
    }
  }

  selectedIds() {
    return this.checkboxTargets.filter(cb => cb.checked).map(cb => cb.value)
  }
}

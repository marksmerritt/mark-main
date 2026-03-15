import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["content", "arrow", "rows", "remaining"]
  static values = { total: Number }

  toggle() {
    this.contentTarget.classList.toggle("hidden")
    this.arrowTarget.textContent = this.contentTarget.classList.contains("hidden") ? "expand_more" : "expand_less"
  }

  addRow() {
    const row = document.createElement("div")
    row.className = "split-row"
    row.style.cssText = "display: grid; grid-template-columns: 1fr 2fr 1fr; gap: 0.75rem; margin-bottom: 0.5rem;"
    row.innerHTML = `
      <div class="form-group">
        <input type="number" name="splits[][amount]" class="form-control split-amount" step="0.01" required data-action="input->split-transaction#updateRemaining">
      </div>
      <div class="form-group">
        <input type="text" name="splits[][description]" class="form-control" placeholder="Description">
      </div>
      <div class="form-group">
        <button type="button" class="btn btn-sm" data-action="split-transaction#removeRow">Remove</button>
      </div>
    `
    this.rowsTarget.appendChild(row)
  }

  removeRow(event) {
    const row = event.target.closest(".split-row")
    if (this.rowsTarget.children.length > 1) {
      row.remove()
      this.updateRemaining()
    }
  }

  updateRemaining() {
    const inputs = this.rowsTarget.querySelectorAll(".split-amount")
    let allocated = 0
    inputs.forEach(input => {
      allocated += parseFloat(input.value) || 0
    })
    const remaining = this.totalValue - allocated
    this.remainingTarget.textContent = "$" + remaining.toFixed(2)
    this.remainingTarget.style.color = remaining < 0 ? "var(--negative)" : (remaining === 0 ? "var(--positive)" : "")
  }
}

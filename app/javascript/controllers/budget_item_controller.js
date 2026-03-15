import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["amount", "display", "form"]
  static values = { url: String, csrfToken: String, budgetId: Number, categoryId: Number }

  toggle() {
    this.formTarget.classList.toggle("hidden")
  }

  async save(event) {
    event.preventDefault()
    const amount = this.amountTarget.value
    const url = this.urlValue
    const token = this.csrfTokenValue

    try {
      const response = await fetch(url, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": token,
          "Accept": "application/json"
        },
        body: JSON.stringify({ budget_item: { planned_amount: amount } })
      })

      if (response.ok) {
        this.displayTarget.textContent = `$${parseFloat(amount).toFixed(2)}`
        this.formTarget.classList.add("hidden")
      }
    } catch (e) {
      console.error("Failed to update budget item:", e)
    }
  }

  cancel() {
    this.formTarget.classList.add("hidden")
  }
}

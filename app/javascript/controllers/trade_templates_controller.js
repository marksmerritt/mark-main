import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "savedList",
    "emptyState",
    "nameInput",
    "symbolInput",
    "sideInput",
    "quantityInput",
    "assetClassInput",
    "notesInput",
    "formMessage"
  ]

  connect() {
    this.storageKey = "trade_templates"
    this.renderSavedTemplates()
  }

  getTemplates() {
    try {
      const data = localStorage.getItem(this.storageKey)
      return data ? JSON.parse(data) : []
    } catch {
      return []
    }
  }

  saveTemplates(templates) {
    localStorage.setItem(this.storageKey, JSON.stringify(templates))
  }

  renderSavedTemplates() {
    const templates = this.getTemplates()
    if (!this.hasSavedListTarget) return

    if (templates.length === 0) {
      this.savedListTarget.innerHTML = ""
      if (this.hasEmptyStateTarget) this.emptyStateTarget.style.display = ""
      return
    }

    if (this.hasEmptyStateTarget) this.emptyStateTarget.style.display = "none"

    this.savedListTarget.innerHTML = templates.map((t, i) => `
      <div class="card" style="padding: 1rem; border-left: 4px solid var(--primary);">
        <div style="display: flex; justify-content: space-between; align-items: flex-start; gap: 1rem;">
          <div style="flex: 1;">
            <div style="font-weight: 700; font-size: 0.9375rem; margin-bottom: 0.375rem;">${this.escapeHtml(t.name)}</div>
            <div style="display: flex; gap: 0.5rem; flex-wrap: wrap; margin-bottom: 0.375rem;">
              <span style="display: inline-flex; align-items: center; gap: 0.25rem; padding: 0.125rem 0.5rem; border-radius: 4px; font-size: 0.75rem; font-weight: 600; background: var(--surface); border: 1px solid var(--border);">${this.escapeHtml(t.symbol)}</span>
              <span style="display: inline-flex; align-items: center; gap: 0.25rem; padding: 0.125rem 0.5rem; border-radius: 4px; font-size: 0.75rem; font-weight: 600; color: #fff; background: ${t.side === 'long' ? 'var(--positive)' : 'var(--negative)'};">${t.side === 'long' ? 'LONG' : 'SHORT'}</span>
              <span style="font-size: 0.75rem; color: var(--text-secondary);">${t.quantity} shares</span>
              ${t.asset_class ? `<span style="font-size: 0.75rem; color: var(--text-secondary);">${this.escapeHtml(t.asset_class)}</span>` : ''}
            </div>
            ${t.notes ? `<div style="font-size: 0.75rem; color: var(--text-secondary); margin-top: 0.25rem;">${this.escapeHtml(t.notes)}</div>` : ''}
          </div>
          <div style="display: flex; gap: 0.375rem; flex-shrink: 0;">
            <button class="btn btn-sm" style="font-size: 0.75rem; padding: 0.25rem 0.625rem;" data-action="click->trade-templates#useTemplate" data-index="${i}">
              <span class="material-icons-outlined" style="font-size: 0.875rem; vertical-align: -2px;">play_arrow</span> Use
            </button>
            <button class="btn btn-sm" style="font-size: 0.75rem; padding: 0.25rem 0.625rem; color: var(--negative);" data-action="click->trade-templates#deleteTemplate" data-index="${i}">
              <span class="material-icons-outlined" style="font-size: 0.875rem; vertical-align: -2px;">delete</span>
            </button>
          </div>
        </div>
      </div>
    `).join("")
  }

  createTemplate(event) {
    event.preventDefault()

    const name = this.nameInputTarget.value.trim()
    const symbol = this.symbolInputTarget.value.trim().toUpperCase()
    const side = this.sideInputTarget.value
    const quantity = parseInt(this.quantityInputTarget.value, 10)
    const assetClass = this.assetClassInputTarget.value.trim()
    const notes = this.notesInputTarget.value.trim()

    if (!name || !symbol || !quantity || quantity <= 0) {
      this.showFormMessage("Please fill in name, symbol, and a valid quantity.", "var(--negative)")
      return
    }

    const templates = this.getTemplates()
    templates.push({
      name,
      symbol,
      side,
      quantity,
      asset_class: assetClass || "Equity",
      notes: notes || "",
      playbook_id: null,
      risk_amount: null,
      created_at: new Date().toISOString()
    })

    this.saveTemplates(templates)
    this.renderSavedTemplates()
    this.clearForm()
    this.showFormMessage("Template saved!", "var(--positive)")
  }

  deleteTemplate(event) {
    const index = parseInt(event.currentTarget.dataset.index, 10)
    const templates = this.getTemplates()
    if (index >= 0 && index < templates.length) {
      const name = templates[index].name
      if (confirm(`Delete template "${name}"?`)) {
        templates.splice(index, 1)
        this.saveTemplates(templates)
        this.renderSavedTemplates()
      }
    }
  }

  useTemplate(event) {
    const index = parseInt(event.currentTarget.dataset.index, 10)
    const templates = this.getTemplates()
    if (index >= 0 && index < templates.length) {
      this.navigateToNewTrade(templates[index])
    }
  }

  useSuggested(event) {
    const data = event.currentTarget.dataset
    this.navigateToNewTrade({
      symbol: data.symbol,
      side: data.side,
      quantity: data.quantity,
      asset_class: data.assetClass || ""
    })
  }

  saveSuggested(event) {
    const data = event.currentTarget.dataset
    const templates = this.getTemplates()

    const template = {
      name: data.name,
      symbol: data.symbol,
      side: data.side,
      quantity: parseInt(data.quantity, 10),
      asset_class: data.assetClass || "Equity",
      notes: data.notes || "",
      playbook_id: data.playbookId ? parseInt(data.playbookId, 10) : null,
      risk_amount: null,
      created_at: new Date().toISOString()
    }

    // Check for duplicate
    const exists = templates.some(t => t.name === template.name && t.symbol === template.symbol)
    if (exists) {
      this.showFormMessage("A template with this name and symbol already exists.", "var(--negative)")
      return
    }

    templates.push(template)
    this.saveTemplates(templates)
    this.renderSavedTemplates()
    this.showFormMessage(`"${template.name}" saved to your templates!`, "var(--positive)")
  }

  navigateToNewTrade(template) {
    const params = new URLSearchParams()
    if (template.symbol) params.set("trade[symbol]", template.symbol)
    if (template.side) params.set("trade[side]", template.side)
    if (template.quantity) params.set("trade[quantity]", template.quantity)
    if (template.asset_class) params.set("trade[asset_class]", template.asset_class)
    window.location.href = `/trades/new?${params.toString()}`
  }

  clearForm() {
    this.nameInputTarget.value = ""
    this.symbolInputTarget.value = ""
    this.sideInputTarget.value = "long"
    this.quantityInputTarget.value = ""
    this.assetClassInputTarget.value = ""
    this.notesInputTarget.value = ""
  }

  showFormMessage(msg, color) {
    if (!this.hasFormMessageTarget) return
    this.formMessageTarget.textContent = msg
    this.formMessageTarget.style.color = color
    this.formMessageTarget.style.display = ""
    setTimeout(() => {
      this.formMessageTarget.style.display = "none"
    }, 3000)
  }

  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }
}

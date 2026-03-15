import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["searchInput", "searchResults", "selectedList", "hiddenIds", "submitBtn", "emptyState"]
  static values = { trades: Array, selectedIds: Array, maxTrades: { type: Number, default: 4 } }

  connect() {
    this.selected = new Map()
    this.timeout = null

    // Restore any currently-compared trade IDs from the URL
    const url = new URL(window.location)
    const existingIds = url.searchParams.getAll("trade_ids[]")
    if (existingIds.length > 0) {
      const allTrades = this.tradesValue || []
      existingIds.forEach(id => {
        const trade = allTrades.find(t => String(t.id) === String(id))
        if (trade) {
          this.selected.set(String(id), trade)
        }
      })
    }
    this.renderSelected()
  }

  disconnect() {
    if (this.timeout) clearTimeout(this.timeout)
  }

  search() {
    if (this.timeout) clearTimeout(this.timeout)
    this.timeout = setTimeout(() => this.performSearch(), 150)
  }

  performSearch() {
    const query = this.searchInputTarget.value.trim().toUpperCase()
    if (query.length < 1) {
      this.searchResultsTarget.innerHTML = ""
      this.searchResultsTarget.classList.add("hidden")
      return
    }

    const trades = this.tradesValue || []
    const matches = trades.filter(t => {
      if (this.selected.has(String(t.id))) return false
      const symbol = (t.symbol || "").toUpperCase()
      const side = (t.side || "").toUpperCase()
      const id = String(t.id)
      return symbol.includes(query) || side.includes(query) || id.includes(query)
    }).slice(0, 8)

    if (matches.length === 0) {
      this.searchResultsTarget.innerHTML = `<div class="tc-no-results">No matching trades</div>`
      this.searchResultsTarget.classList.remove("hidden")
      return
    }

    this.searchResultsTarget.innerHTML = matches.map(t => {
      const pnl = parseFloat(t.pnl) || 0
      const pnlClass = pnl >= 0 ? "positive" : "negative"
      const pnlStr = pnl >= 0 ? `+$${pnl.toFixed(2)}` : `-$${Math.abs(pnl).toFixed(2)}`
      const date = t.entry_time ? new Date(t.entry_time).toLocaleDateString("en-US", { month: "short", day: "numeric" }) : ""
      return `<div class="tc-result-item" data-action="click->trade-comparison#addTrade" data-id="${t.id}" data-symbol="${t.symbol || ''}" data-side="${t.side || ''}" data-pnl="${t.pnl || 0}" data-entry-time="${t.entry_time || ''}">
        <span class="tc-result-symbol">${t.symbol || 'N/A'}</span>
        <span class="tc-result-side">${(t.side || '').charAt(0).toUpperCase() + (t.side || '').slice(1)}</span>
        <span class="tc-result-pnl ${pnlClass}">${pnlStr}</span>
        <span class="tc-result-date">${date}</span>
      </div>`
    }).join("")
    this.searchResultsTarget.classList.remove("hidden")
  }

  addTrade(event) {
    const el = event.currentTarget
    if (this.selected.size >= this.maxTradesValue) {
      alert(`You can compare up to ${this.maxTradesValue} trades at a time.`)
      return
    }

    const id = String(el.dataset.id)
    if (this.selected.has(id)) return

    this.selected.set(id, {
      id: el.dataset.id,
      symbol: el.dataset.symbol,
      side: el.dataset.side,
      pnl: el.dataset.pnl,
      entry_time: el.dataset.entryTime
    })

    this.searchInputTarget.value = ""
    this.searchResultsTarget.innerHTML = ""
    this.searchResultsTarget.classList.add("hidden")
    this.renderSelected()
  }

  removeTrade(event) {
    const id = String(event.currentTarget.dataset.id)
    this.selected.delete(id)
    this.renderSelected()
  }

  renderSelected() {
    const list = this.selectedListTarget
    const ids = Array.from(this.selected.keys())

    if (ids.length === 0) {
      list.innerHTML = ""
      if (this.hasEmptyStateTarget) this.emptyStateTarget.classList.remove("hidden")
      this.submitBtnTarget.disabled = true
      this.submitBtnTarget.textContent = "Select at least 2 trades"
      return
    }

    if (this.hasEmptyStateTarget) this.emptyStateTarget.classList.add("hidden")
    this.submitBtnTarget.disabled = ids.length < 2
    this.submitBtnTarget.textContent = ids.length < 2
      ? "Select at least 2 trades"
      : `Compare ${ids.length} Trades`

    list.innerHTML = ids.map(id => {
      const t = this.selected.get(id)
      const pnl = parseFloat(t.pnl) || 0
      const pnlClass = pnl >= 0 ? "positive" : "negative"
      const pnlStr = pnl >= 0 ? `+$${pnl.toFixed(2)}` : `-$${Math.abs(pnl).toFixed(2)}`
      return `<div class="tc-selected-chip">
        <span class="tc-chip-symbol">${t.symbol || 'N/A'}</span>
        <span class="tc-chip-pnl ${pnlClass}">${pnlStr}</span>
        <button type="button" class="tc-chip-remove" data-action="click->trade-comparison#removeTrade" data-id="${id}" title="Remove">
          <span class="material-icons-outlined" style="font-size: 14px;">close</span>
        </button>
      </div>`
    }).join("")

    // Update hidden input
    this.hiddenIdsTarget.value = ids.join(",")
  }

  submit(event) {
    event.preventDefault()
    const ids = Array.from(this.selected.keys())
    if (ids.length < 2) {
      alert("Select at least 2 trades to compare.")
      return
    }
    const params = ids.map(id => `trade_ids[]=${id}`).join("&")
    window.location.href = `/comparison?${params}`
  }

  clearAll() {
    this.selected.clear()
    this.renderSelected()
  }

  // Keyboard navigation for search results
  keydown(event) {
    const items = this.searchResultsTarget.querySelectorAll(".tc-result-item")
    if (!items.length) return

    if (event.key === "Escape") {
      this.searchResultsTarget.innerHTML = ""
      this.searchResultsTarget.classList.add("hidden")
      return
    }
  }
}

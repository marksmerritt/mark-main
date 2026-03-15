import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["suggestions", "symbol", "side", "setup", "assetClass", "entryTime"]
  static values = { tags: Array, history: Object }

  connect() {
    this.updateSuggestions()
  }

  update() {
    this.updateSuggestions()
  }

  updateSuggestions() {
    const suggestions = new Set()

    // Side-based suggestions
    const side = this.sideValue()
    if (side === "long") suggestions.add("long")
    if (side === "short") suggestions.add("short")

    // Asset class suggestions
    const asset = this.assetClassValue()
    if (asset) suggestions.add(asset)

    // Time-based suggestions
    const entryTime = this.entryTimeValue()
    if (entryTime) {
      const hour = new Date(entryTime).getHours()
      if (hour < 10) suggestions.add("morning")
      else if (hour >= 10 && hour < 12) suggestions.add("mid-morning")
      else if (hour >= 12 && hour < 14) suggestions.add("midday")
      else if (hour >= 14 && hour < 15) suggestions.add("afternoon")
      else if (hour >= 15) suggestions.add("power-hour")

      const day = new Date(entryTime).getDay()
      if (day === 1) suggestions.add("monday")
      if (day === 5) suggestions.add("friday")
    }

    // Setup-based suggestions
    const setup = this.setupValue()
    if (setup) {
      const lower = setup.toLowerCase()
      const patterns = {
        "breakout": "breakout", "breakdown": "breakdown",
        "reversal": "reversal", "pullback": "pullback",
        "gap": "gap", "momentum": "momentum",
        "scalp": "scalp", "swing": "swing",
        "trend": "trend-following", "range": "range-bound",
        "earnings": "earnings", "news": "catalyst",
        "vwap": "vwap", "ema": "moving-average",
        "support": "support-bounce", "resistance": "resistance-rejection",
        "flag": "flag-pattern", "wedge": "wedge-pattern",
        "channel": "channel-trade", "squeeze": "squeeze"
      }
      for (const [keyword, tag] of Object.entries(patterns)) {
        if (lower.includes(keyword)) suggestions.add(tag)
      }
    }

    // Historical symbol-based suggestions
    const symbol = this.symbolValue()
    if (symbol && this.historyValue[symbol]) {
      this.historyValue[symbol].forEach(tag => suggestions.add(tag))
    }

    this.renderSuggestions(suggestions)
  }

  renderSuggestions(suggestions) {
    if (!this.hasSuggestionsTarget) return

    // Filter to only show suggestions not already checked
    const checked = new Set(
      Array.from(document.querySelectorAll('input[name="tag_ids[]"]:checked'))
        .map(cb => cb.closest('label')?.querySelector('.tag')?.textContent?.trim()?.toLowerCase())
        .filter(Boolean)
    )

    const available = this.tagsValue.filter(tag =>
      suggestions.has(tag.name?.toLowerCase()) && !checked.has(tag.name?.toLowerCase())
    )

    if (available.length === 0) {
      this.suggestionsTarget.innerHTML = ""
      this.suggestionsTarget.classList.add("hidden")
      return
    }

    this.suggestionsTarget.classList.remove("hidden")
    this.suggestionsTarget.innerHTML = `
      <span class="tag-suggest-label">
        <span class="material-icons-outlined" style="font-size: 0.875rem;">auto_awesome</span>
        Suggested:
      </span>
      ${available.map(tag => `
        <button type="button" class="tag-suggest-btn" data-action="tag-suggest#apply" data-tag-id="${tag.id}"
                ${tag.color ? `style="border-color: ${tag.color};"` : ""}>
          ${tag.name}
        </button>
      `).join("")}
    `
  }

  apply(event) {
    const tagId = event.currentTarget.dataset.tagId
    const checkbox = document.getElementById(`tag_${tagId}`)
    if (checkbox) {
      checkbox.checked = true
      this.updateSuggestions()
    }
  }

  // Value readers
  sideValue() {
    return this.hasSideTarget ? this.sideTarget.value : ""
  }
  assetClassValue() {
    return this.hasAssetClassTarget ? this.assetClassTarget.value : ""
  }
  entryTimeValue() {
    return this.hasEntryTimeTarget ? this.entryTimeTarget.value : ""
  }
  setupValue() {
    return this.hasSetupTarget ? this.setupTarget.value : ""
  }
  symbolValue() {
    return this.hasSymbolTarget ? this.symbolTarget.value?.toUpperCase() : ""
  }
}

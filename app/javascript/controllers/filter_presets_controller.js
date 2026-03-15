import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["list", "nameInput", "form"]

  connect() {
    this.renderPresets()
  }

  get presets() {
    try {
      return JSON.parse(localStorage.getItem("trade_filter_presets") || "[]")
    } catch {
      return []
    }
  }

  set presets(value) {
    localStorage.setItem("trade_filter_presets", JSON.stringify(value))
  }

  save() {
    const name = this.nameInputTarget.value.trim()
    if (!name) {
      alert("Enter a preset name.")
      return
    }

    const form = this.formTarget
    const formData = new FormData(form)
    const params = {}
    for (const [key, value] of formData.entries()) {
      if (value && key !== "authenticity_token" && key !== "commit") {
        params[key] = value
      }
    }

    if (Object.keys(params).length === 0) {
      alert("Set at least one filter before saving.")
      return
    }

    const presets = this.presets
    const existing = presets.findIndex(p => p.name === name)
    if (existing >= 0) {
      presets[existing].params = params
    } else {
      presets.push({ name, params })
    }
    this.presets = presets
    this.nameInputTarget.value = ""
    this.renderPresets()
  }

  apply(event) {
    const idx = parseInt(event.currentTarget.dataset.index)
    const preset = this.presets[idx]
    if (!preset) return

    const url = new URL(window.location.pathname, window.location.origin)
    for (const [key, value] of Object.entries(preset.params)) {
      url.searchParams.set(key, value)
    }
    window.location.href = url.toString()
  }

  remove(event) {
    event.stopPropagation()
    const idx = parseInt(event.currentTarget.dataset.index)
    const presets = this.presets
    presets.splice(idx, 1)
    this.presets = presets
    this.renderPresets()
  }

  renderPresets() {
    if (!this.hasListTarget) return
    const presets = this.presets

    if (presets.length === 0) {
      this.listTarget.innerHTML = '<span class="text-muted" style="font-size: 0.8125rem;">No saved presets</span>'
      return
    }

    this.listTarget.innerHTML = presets.map((preset, i) => {
      const summary = Object.entries(preset.params)
        .map(([k, v]) => `${k.replace(/_/g, " ")}: ${v}`)
        .join(", ")
      return `
        <button type="button" class="preset-chip" data-action="filter-presets#apply" data-index="${i}" title="${summary}">
          ${preset.name}
          <span class="preset-remove" data-action="click->filter-presets#remove" data-index="${i}">&times;</span>
        </button>
      `
    }).join("")
  }
}

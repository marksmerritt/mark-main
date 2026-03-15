import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["header", "body"]

  connect() {
    this.storageKey = "sortable_trades"
    const saved = this.loadPreference()
    this.currentColumn = saved.column ?? "entry_time"
    this.currentDirection = saved.direction ?? "desc"
    this.applySort()
  }

  sort(event) {
    const th = event.currentTarget
    const column = th.dataset.sortColumn
    if (!column) return

    if (this.currentColumn === column) {
      this.currentDirection = this.currentDirection === "asc" ? "desc" : "asc"
    } else {
      this.currentColumn = column
      this.currentDirection = "asc"
    }

    this.savePreference()
    this.applySort()
  }

  applySort() {
    const tbody = this.bodyTarget
    const rows = Array.from(tbody.querySelectorAll("tr"))
    const headerIndex = this.columnIndex(this.currentColumn)

    if (headerIndex === -1) return

    const sortType = this.sortTypeForColumn(this.currentColumn)

    rows.sort((a, b) => {
      const aVal = this.extractValue(a.children[headerIndex], sortType)
      const bVal = this.extractValue(b.children[headerIndex], sortType)
      let result = this.compare(aVal, bVal, sortType)
      return this.currentDirection === "desc" ? -result : result
    })

    rows.forEach(row => tbody.appendChild(row))
    this.updateIndicators()
  }

  extractValue(cell, sortType) {
    if (!cell) return ""
    const text = cell.textContent.trim()

    switch (sortType) {
      case "number":
        return parseFloat(text.replace(/,/g, "")) || 0
      case "currency":
        return parseFloat(text.replace(/[$,()]/g, "").replace(/^\u2014$/, "0")) || 0
      case "date":
        return new Date(text) || 0
      case "percentage":
        return parseFloat(text.replace(/%/g, "")) || 0
      default:
        return text.toLowerCase()
    }
  }

  compare(a, b, sortType) {
    if (sortType === "date") {
      return (a instanceof Date ? a.getTime() : 0) - (b instanceof Date ? b.getTime() : 0)
    }
    if (typeof a === "number" && typeof b === "number") {
      return a - b
    }
    return String(a).localeCompare(String(b))
  }

  columnIndex(column) {
    const headers = this.headerTargets
    for (let i = 0; i < headers.length; i++) {
      if (headers[i].dataset.sortColumn === column) {
        return Array.from(headers[i].parentElement.children).indexOf(headers[i])
      }
    }
    return -1
  }

  sortTypeForColumn(column) {
    const headers = this.headerTargets
    for (const h of headers) {
      if (h.dataset.sortColumn === column) {
        return h.dataset.sortType || "text"
      }
    }
    return "text"
  }

  updateIndicators() {
    this.headerTargets.forEach(th => {
      let indicator = th.querySelector(".sort-indicator")
      if (!indicator) {
        indicator = document.createElement("span")
        indicator.className = "sort-indicator"
        th.appendChild(indicator)
      }

      if (th.dataset.sortColumn === this.currentColumn) {
        indicator.textContent = this.currentDirection === "asc" ? " \u25B2" : " \u25BC"
        indicator.classList.add("active")
      } else {
        indicator.textContent = ""
        indicator.classList.remove("active")
      }
    })
  }

  loadPreference() {
    try {
      const saved = localStorage.getItem(this.storageKey)
      return saved ? JSON.parse(saved) : {}
    } catch {
      return {}
    }
  }

  savePreference() {
    try {
      localStorage.setItem(this.storageKey, JSON.stringify({
        column: this.currentColumn,
        direction: this.currentDirection
      }))
    } catch {
      // localStorage unavailable
    }
  }
}

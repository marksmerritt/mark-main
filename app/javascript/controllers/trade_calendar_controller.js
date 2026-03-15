import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    trades: Array
  }

  static targets = ["grid", "tooltip"]

  connect() {
    this.render()
  }

  tradesValueChanged() {
    this.render()
  }

  render() {
    const trades = this.tradesValue || []
    const grid = this.gridTarget

    grid.innerHTML = ""

    // Build daily P&L from trades
    const dailyPnl = {}
    const dailyCount = {}
    trades.forEach(trade => {
      if (trade.status !== "closed" || trade.pnl === null || trade.pnl === undefined) return
      const date = (trade.entry_time || "").slice(0, 10)
      if (!date) return
      dailyPnl[date] = (dailyPnl[date] || 0) + parseFloat(trade.pnl || 0)
      dailyCount[date] = (dailyCount[date] || 0) + 1
    })

    // Determine the date range: last 52 weeks
    const today = new Date()
    const endDate = new Date(today.getFullYear(), today.getMonth(), today.getDate())

    const startDate = new Date(endDate)
    startDate.setDate(startDate.getDate() - 363)
    // Align to the previous Sunday
    const dayOfWeek = startDate.getDay()
    startDate.setDate(startDate.getDate() - dayOfWeek)

    // Compute absolute max PnL for color scaling
    const pnlValues = Object.values(dailyPnl).filter(v => !isNaN(v))
    const maxAbsPnl = pnlValues.length > 0 ? Math.max(...pnlValues.map(v => Math.abs(v))) : 1

    // Build cells
    const cells = []
    const current = new Date(startDate)
    let weekIndex = 0
    let lastMonth = -1

    while (current <= endDate) {
      const dow = current.getDay()
      const dateStr = this.formatDate(current)
      const pnlVal = dailyPnl[dateStr] !== undefined ? dailyPnl[dateStr] : null
      const count = dailyCount[dateStr] || 0

      // Track month labels
      const month = current.getMonth()
      if (month !== lastMonth && dow === 0) {
        cells.push({
          type: "month-label",
          month: current.toLocaleString("default", { month: "short" }),
          weekIndex: weekIndex
        })
        lastMonth = month
      }

      const colorClass = this.colorClass(pnlVal, maxAbsPnl)
      cells.push({
        type: "cell",
        date: dateStr,
        pnl: pnlVal,
        count: count,
        pnlFormatted: pnlVal !== null ? this.formatCurrency(pnlVal) : "No trades",
        dow: dow,
        weekIndex: weekIndex,
        colorClass: colorClass
      })

      current.setDate(current.getDate() + 1)
      if (current.getDay() === 0) weekIndex++
    }

    const totalWeeks = weekIndex + 1

    // Render month labels row
    const monthRow = document.createElement("div")
    monthRow.className = "heatmap-months"
    monthRow.style.gridTemplateColumns = `2rem repeat(${totalWeeks}, 1fr)`

    const monthLabels = cells.filter(c => c.type === "month-label")
    const monthPositions = new Map()
    monthLabels.forEach(ml => {
      monthPositions.set(ml.weekIndex, ml.month)
    })

    let monthHtml = `<div></div>`
    for (let w = 0; w < totalWeeks; w++) {
      const label = monthPositions.get(w) || ""
      monthHtml += `<div class="heatmap-month-label">${label}</div>`
    }
    monthRow.innerHTML = monthHtml
    grid.appendChild(monthRow)

    // Render the heatmap grid with day labels
    const heatmapGrid = document.createElement("div")
    heatmapGrid.className = "heatmap-grid"
    heatmapGrid.style.gridTemplateColumns = `2rem repeat(${totalWeeks}, 1fr)`

    const dayLabels = ["", "Mon", "", "Wed", "", "Fri", ""]
    for (let dow = 0; dow < 7; dow++) {
      const label = document.createElement("div")
      label.className = "heatmap-day-label"
      label.textContent = dayLabels[dow]
      heatmapGrid.appendChild(label)

      for (let w = 0; w < totalWeeks; w++) {
        const cell = cells.find(c => c.type === "cell" && c.dow === dow && c.weekIndex === w)
        const el = document.createElement("div")
        if (cell) {
          el.className = `heatmap-cell ${cell.colorClass}`
          el.setAttribute("data-action", "mouseenter->trade-calendar#showTooltip mouseleave->trade-calendar#hideTooltip")
          el.setAttribute("data-date", cell.date)
          el.setAttribute("data-pnl", cell.pnlFormatted)
          el.setAttribute("data-count", cell.count)
        } else {
          el.className = "heatmap-cell heatmap-empty"
        }
        heatmapGrid.appendChild(el)
      }
    }

    grid.appendChild(heatmapGrid)
  }

  showTooltip(event) {
    const cell = event.currentTarget
    const date = cell.getAttribute("data-date")
    const pnl = cell.getAttribute("data-pnl")
    const count = parseInt(cell.getAttribute("data-count") || "0")
    const tooltip = this.tooltipTarget

    let html = `<strong>${date}</strong><br>${pnl}`
    if (count > 0) {
      html += `<br><span style="opacity:0.7">${count} trade${count !== 1 ? "s" : ""}</span>`
    }
    tooltip.innerHTML = html
    tooltip.classList.add("heatmap-tooltip-visible")

    const rect = cell.getBoundingClientRect()
    const containerRect = this.element.getBoundingClientRect()
    const tooltipRect = tooltip.getBoundingClientRect()

    let left = rect.left - containerRect.left + rect.width / 2 - tooltipRect.width / 2
    let top = rect.top - containerRect.top - tooltipRect.height - 8

    if (left < 0) left = 0
    if (left + tooltipRect.width > containerRect.width) {
      left = containerRect.width - tooltipRect.width
    }
    if (top < 0) {
      top = rect.bottom - containerRect.top + 8
    }

    tooltip.style.left = `${left}px`
    tooltip.style.top = `${top}px`
  }

  hideTooltip() {
    this.tooltipTarget.classList.remove("heatmap-tooltip-visible")
  }

  colorClass(pnl, maxAbsPnl) {
    if (pnl === null) return "heatmap-level-0"
    if (pnl === 0) return "heatmap-level-0"

    const ratio = Math.abs(pnl) / maxAbsPnl

    if (pnl > 0) {
      if (ratio > 0.75) return "heatmap-profit-4"
      if (ratio > 0.50) return "heatmap-profit-3"
      if (ratio > 0.25) return "heatmap-profit-2"
      return "heatmap-profit-1"
    } else {
      if (ratio > 0.75) return "heatmap-loss-4"
      if (ratio > 0.50) return "heatmap-loss-3"
      if (ratio > 0.25) return "heatmap-loss-2"
      return "heatmap-loss-1"
    }
  }

  formatDate(date) {
    const y = date.getFullYear()
    const m = String(date.getMonth() + 1).padStart(2, "0")
    const d = String(date.getDate()).padStart(2, "0")
    return `${y}-${m}-${d}`
  }

  formatCurrency(val) {
    const sign = val >= 0 ? "+" : ""
    return `${sign}$${Math.abs(val).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
  }
}

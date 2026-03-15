import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["container", "tooltip"]
  static values = { data: Array }

  connect() {
    this.render()
    this.resizeObserver = new ResizeObserver(() => this.render())
    this.resizeObserver.observe(this.containerTarget)
  }

  disconnect() {
    this.resizeObserver?.disconnect()
  }

  render() {
    const data = this.dataValue
    if (!data.length) return

    const width = this.containerTarget.clientWidth
    const height = Math.max(300, Math.min(500, width * 0.5))

    // Sort by absolute value (largest first) for treemap layout
    const sorted = [...data].sort((a, b) => Math.abs(b.value) - Math.abs(a.value))
    const totalValue = sorted.reduce((sum, d) => sum + Math.abs(d.value), 0)
    if (totalValue === 0) return

    // Squarified treemap layout
    const rects = this.squarify(sorted.map(d => ({
      ...d,
      area: Math.abs(d.value) / totalValue * width * height
    })), { x: 0, y: 0, w: width, h: height })

    // Find max absolute P&L for color scaling
    const maxPnl = Math.max(...data.map(d => Math.abs(d.pnl)))

    let svg = `<svg width="${width}" height="${height}" class="treemap-svg">`

    rects.forEach(r => {
      const intensity = maxPnl > 0 ? Math.min(Math.abs(r.pnl) / maxPnl, 1) : 0
      const color = r.pnl >= 0
        ? this.interpolateColor([240, 249, 240], [13, 144, 79], intensity)
        : this.interpolateColor([254, 243, 242], [217, 48, 37], intensity)

      const fontSize = Math.min(r.w / (r.label.length * 0.7), r.h * 0.35, 18)
      const showLabel = fontSize >= 8 && r.w > 30 && r.h > 20
      const showValue = fontSize >= 7 && r.h > 35

      svg += `<g class="treemap-cell" data-action="mouseenter->treemap#showTooltip mouseleave->treemap#hideTooltip"
                data-label="${r.label}" data-pnl="${r.pnl}" data-trades="${r.trades}" data-winrate="${r.winRate}">`
      svg += `<rect x="${r.x}" y="${r.y}" width="${r.w}" height="${r.h}" fill="rgb(${color})" stroke="var(--surface)" stroke-width="2" rx="3"/>`

      if (showLabel) {
        const textColor = intensity > 0.5 ? "#fff" : "var(--text)"
        svg += `<text x="${r.x + r.w / 2}" y="${r.y + r.h / 2 - (showValue ? fontSize * 0.3 : 0)}" text-anchor="middle" dominant-baseline="central" fill="${textColor}" font-size="${fontSize}px" font-weight="600">${r.label}</text>`

        if (showValue) {
          const pnlStr = r.pnl >= 0 ? `+$${r.pnl.toFixed(0)}` : `-$${Math.abs(r.pnl).toFixed(0)}`
          svg += `<text x="${r.x + r.w / 2}" y="${r.y + r.h / 2 + fontSize * 0.8}" text-anchor="middle" dominant-baseline="central" fill="${textColor}" font-size="${Math.max(fontSize * 0.65, 9)}px" opacity="0.9">${pnlStr}</text>`
        }
      }
      svg += `</g>`
    })

    svg += `</svg>`
    this.containerTarget.innerHTML = svg
  }

  squarify(items, rect) {
    if (!items.length) return []
    if (items.length === 1) {
      return [{ ...items[0], x: rect.x, y: rect.y, w: rect.w, h: rect.h }]
    }

    const totalArea = items.reduce((s, d) => s + d.area, 0)
    const results = []
    let row = []
    let rowArea = 0
    let remaining = [...items]
    let currentRect = { ...rect }

    while (remaining.length > 0) {
      const item = remaining[0]
      const testRow = [...row, item]
      const testArea = rowArea + item.area

      if (row.length === 0 || this.worstRatio(testRow, testArea, currentRect) <= this.worstRatio(row, rowArea, currentRect)) {
        row.push(item)
        rowArea += item.area
        remaining.shift()
      } else {
        // Layout current row
        const laid = this.layoutRow(row, rowArea, currentRect)
        results.push(...laid)
        currentRect = this.remainingRect(currentRect, rowArea)
        row = []
        rowArea = 0
      }
    }

    if (row.length > 0) {
      results.push(...this.layoutRow(row, rowArea, currentRect))
    }

    return results
  }

  worstRatio(row, rowArea, rect) {
    if (!row.length) return Infinity
    const side = Math.min(rect.w, rect.h)
    const rowLength = rowArea / side
    let worst = 0
    for (const item of row) {
      const itemSide = item.area / rowLength
      const ratio = Math.max(rowLength / itemSide, itemSide / rowLength)
      if (ratio > worst) worst = ratio
    }
    return worst
  }

  layoutRow(row, rowArea, rect) {
    const isHorizontal = rect.w >= rect.h
    const side = isHorizontal ? rect.h : rect.w
    const rowLength = rowArea / side

    let offset = 0
    return row.map(item => {
      const itemSide = item.area / rowLength
      const result = isHorizontal
        ? { ...item, x: rect.x, y: rect.y + offset, w: rowLength, h: itemSide }
        : { ...item, x: rect.x + offset, y: rect.y, w: itemSide, h: rowLength }
      offset += itemSide
      return result
    })
  }

  remainingRect(rect, usedArea) {
    const isHorizontal = rect.w >= rect.h
    const side = isHorizontal ? rect.h : rect.w
    const rowLength = usedArea / side

    return isHorizontal
      ? { x: rect.x + rowLength, y: rect.y, w: rect.w - rowLength, h: rect.h }
      : { x: rect.x, y: rect.y + rowLength, w: rect.w, h: rect.h - rowLength }
  }

  interpolateColor(from, to, t) {
    return [
      Math.round(from[0] + (to[0] - from[0]) * t),
      Math.round(from[1] + (to[1] - from[1]) * t),
      Math.round(from[2] + (to[2] - from[2]) * t)
    ].join(",")
  }

  showTooltip(event) {
    if (!this.hasTooltipTarget) return
    const cell = event.currentTarget
    const label = cell.dataset.label
    const pnl = parseFloat(cell.dataset.pnl)
    const trades = cell.dataset.trades
    const winRate = cell.dataset.winrate

    const pnlStr = pnl >= 0 ? `+$${pnl.toFixed(2)}` : `-$${Math.abs(pnl).toFixed(2)}`
    const pnlClass = pnl >= 0 ? "positive" : "negative"

    this.tooltipTarget.innerHTML = `
      <strong>${label}</strong><br>
      P&L: <span class="${pnlClass}">${pnlStr}</span><br>
      Trades: ${trades} · Win Rate: ${winRate}%
    `
    this.tooltipTarget.classList.add("visible")

    const rect = this.containerTarget.getBoundingClientRect()
    const x = event.clientX - rect.left + 12
    const y = event.clientY - rect.top - 10
    this.tooltipTarget.style.left = `${x}px`
    this.tooltipTarget.style.top = `${y}px`
  }

  hideTooltip() {
    if (this.hasTooltipTarget) {
      this.tooltipTarget.classList.remove("visible")
    }
  }
}

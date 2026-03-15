import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    points: Array,
    type: { type: String, default: "line" }
  }

  connect() {
    this.render()
  }

  pointsValueChanged() {
    this.render()
  }

  render() {
    if (!this.pointsValue || this.pointsValue.length === 0) return

    if (this.typeValue === "bar") {
      this.renderBar()
    } else if (this.typeValue === "histogram") {
      this.renderHistogram()
    } else if (this.typeValue === "scatter") {
      this.renderScatter()
    } else {
      this.renderLine()
    }
  }

  renderLine() {
    const points = this.pointsValue
    const padding = { top: 20, right: 20, bottom: 40, left: 60 }
    const width = 800
    const height = 300
    const chartW = width - padding.left - padding.right
    const chartH = height - padding.top - padding.bottom

    const xs = points.map(p => p.x)
    const ys = points.map(p => parseFloat(p.y))
    const minY = Math.min(0, ...ys)
    const maxY = Math.max(0, ...ys)
    const rangeY = maxY - minY || 1

    const scaleX = (i) => padding.left + (i / (points.length - 1 || 1)) * chartW
    const scaleY = (v) => padding.top + chartH - ((v - minY) / rangeY) * chartH

    // Build polyline points
    const polyPoints = points.map((p, i) => `${scaleX(i)},${scaleY(parseFloat(p.y))}`).join(" ")

    // Fill area
    const areaPoints = [
      `${scaleX(0)},${scaleY(0)}`,
      ...points.map((p, i) => `${scaleX(i)},${scaleY(parseFloat(p.y))}`),
      `${scaleX(points.length - 1)},${scaleY(0)}`
    ].join(" ")

    // Zero line Y
    const zeroY = scaleY(0)

    // Grid lines (5 horizontal)
    const gridLines = []
    const gridLabels = []
    const steps = 5
    for (let i = 0; i <= steps; i++) {
      const val = minY + (rangeY * i / steps)
      const y = scaleY(val)
      gridLines.push(`<line x1="${padding.left}" y1="${y}" x2="${width - padding.right}" y2="${y}" stroke="var(--border)" stroke-width="1" stroke-dasharray="4,4"/>`)
      gridLabels.push(`<text x="${padding.left - 8}" y="${y + 4}" text-anchor="end" fill="var(--text-secondary)" font-size="11">${this.formatNumber(val)}</text>`)
    }

    // X-axis labels (show ~6 labels max)
    const xLabels = []
    const labelCount = Math.min(6, points.length)
    for (let i = 0; i < labelCount; i++) {
      const idx = Math.round(i * (points.length - 1) / (labelCount - 1 || 1))
      const x = scaleX(idx)
      const label = this.formatLabel(xs[idx])
      xLabels.push(`<text x="${x}" y="${height - 5}" text-anchor="middle" fill="var(--text-secondary)" font-size="11">${label}</text>`)
    }

    const svg = `
      <svg viewBox="0 0 ${width} ${height}" width="100%" height="auto" xmlns="http://www.w3.org/2000/svg" style="overflow:visible;">
        ${gridLines.join("")}
        ${gridLabels.join("")}
        <line x1="${padding.left}" y1="${zeroY}" x2="${width - padding.right}" y2="${zeroY}" stroke="var(--text-secondary)" stroke-width="1" opacity="0.5"/>
        <polygon points="${areaPoints}" fill="var(--primary)" opacity="0.15"/>
        <polyline points="${polyPoints}" fill="none" stroke="var(--primary)" stroke-width="2.5" stroke-linejoin="round" stroke-linecap="round"/>
        ${points.map((p, i) => `<circle cx="${scaleX(i)}" cy="${scaleY(parseFloat(p.y))}" r="4" fill="var(--primary)" opacity="0" class="chart-dot" data-index="${i}"><title>${this.formatLabel(p.x)}: ${this.formatCurrency(parseFloat(p.y))}</title></circle>`).join("")}
        ${xLabels.join("")}
      </svg>
    `
    this.element.innerHTML = svg
    this.addHoverEffects()
  }

  renderBar() {
    const points = this.pointsValue
    const padding = { top: 20, right: 20, bottom: 40, left: 60 }
    const width = 800
    const height = 300
    const chartW = width - padding.left - padding.right
    const chartH = height - padding.top - padding.bottom

    const ys = points.map(p => parseFloat(p.y))
    const minY = Math.min(0, ...ys)
    const maxY = Math.max(0, ...ys)
    const rangeY = maxY - minY || 1

    const scaleY = (v) => padding.top + chartH - ((v - minY) / rangeY) * chartH
    const zeroY = scaleY(0)

    const barWidth = Math.max(2, (chartW / points.length) - 2)
    const bars = []

    points.forEach((p, i) => {
      const val = parseFloat(p.y)
      const x = padding.left + (i * chartW / points.length) + 1
      const y = scaleY(val)
      const barH = Math.abs(y - zeroY)
      const barY = val >= 0 ? y : zeroY
      const color = val >= 0 ? "var(--positive)" : "var(--negative)"
      bars.push(`<rect x="${x}" y="${barY}" width="${barWidth}" height="${barH}" fill="${color}" rx="1"/>`)
    })

    // Grid lines
    const gridLines = []
    const gridLabels = []
    const steps = 5
    for (let i = 0; i <= steps; i++) {
      const val = minY + (rangeY * i / steps)
      const y = scaleY(val)
      gridLines.push(`<line x1="${padding.left}" y1="${y}" x2="${width - padding.right}" y2="${y}" stroke="var(--border)" stroke-width="1" stroke-dasharray="4,4"/>`)
      gridLabels.push(`<text x="${padding.left - 8}" y="${y + 4}" text-anchor="end" fill="var(--text-secondary)" font-size="11">${this.formatNumber(val)}</text>`)
    }

    // X-axis labels
    const xLabels = []
    const labelCount = Math.min(8, points.length)
    for (let i = 0; i < labelCount; i++) {
      const idx = Math.round(i * (points.length - 1) / (labelCount - 1 || 1))
      const x = padding.left + (idx * chartW / points.length) + barWidth / 2
      const label = this.formatLabel(points[idx].x)
      xLabels.push(`<text x="${x}" y="${height - 5}" text-anchor="middle" fill="var(--text-secondary)" font-size="11">${label}</text>`)
    }

    const svg = `
      <svg viewBox="0 0 ${width} ${height}" width="100%" height="auto" xmlns="http://www.w3.org/2000/svg" style="overflow:visible;">
        ${gridLines.join("")}
        ${gridLabels.join("")}
        <line x1="${padding.left}" y1="${zeroY}" x2="${width - padding.right}" y2="${zeroY}" stroke="var(--text-secondary)" stroke-width="1" opacity="0.5"/>
        ${bars.join("")}
        ${xLabels.join("")}
      </svg>
    `
    this.element.innerHTML = svg
  }

  renderHistogram() {
    const points = this.pointsValue
    const padding = { top: 20, right: 20, bottom: 50, left: 60 }
    const width = 800
    const height = 320
    const chartW = width - padding.left - padding.right
    const chartH = height - padding.top - padding.bottom

    const ys = points.map(p => parseFloat(p.y))
    const maxY = Math.max(...ys)

    const scaleY = (v) => padding.top + chartH - (v / (maxY || 1)) * chartH
    const barWidth = Math.max(4, (chartW / points.length) - 2)

    const bars = []
    points.forEach((p, i) => {
      const val = parseFloat(p.y)
      if (val === 0) return
      const x = padding.left + (i * chartW / points.length) + 1
      const y = scaleY(val)
      const barH = chartH - (y - padding.top)
      const midpoint = parseFloat(p.midpoint || 0)
      const color = midpoint >= 0 ? "var(--positive)" : "var(--negative)"
      bars.push(`<rect x="${x}" y="${y}" width="${barWidth}" height="${barH}" fill="${color}" rx="2" opacity="0.85"><title>${p.x} to ${p.x2}: ${val} trades</title></rect>`)
    })

    // Grid lines
    const gridLines = []
    const gridLabels = []
    const steps = 5
    for (let i = 0; i <= steps; i++) {
      const val = (maxY * i / steps)
      const y = scaleY(val)
      gridLines.push(`<line x1="${padding.left}" y1="${y}" x2="${width - padding.right}" y2="${y}" stroke="var(--border)" stroke-width="1" stroke-dasharray="4,4"/>`)
      gridLabels.push(`<text x="${padding.left - 8}" y="${y + 4}" text-anchor="end" fill="var(--text-secondary)" font-size="11">${Math.round(val)}</text>`)
    }

    // X-axis labels
    const xLabels = []
    const labelCount = Math.min(8, points.length)
    for (let i = 0; i < labelCount; i++) {
      const idx = Math.round(i * (points.length - 1) / (labelCount - 1 || 1))
      const x = padding.left + (idx * chartW / points.length) + barWidth / 2
      xLabels.push(`<text x="${x}" y="${height - 5}" text-anchor="middle" fill="var(--text-secondary)" font-size="10" transform="rotate(-30, ${x}, ${height - 5})">${points[idx].x}</text>`)
    }

    // Zero line
    const zeroIdx = points.findIndex(p => parseFloat(p.midpoint || 0) >= 0)
    let zeroLine = ""
    if (zeroIdx > 0) {
      const zeroX = padding.left + (zeroIdx * chartW / points.length)
      zeroLine = `<line x1="${zeroX}" y1="${padding.top}" x2="${zeroX}" y2="${padding.top + chartH}" stroke="var(--text-secondary)" stroke-width="1.5" stroke-dasharray="6,3"/>`
    }

    const svg = `
      <svg viewBox="0 0 ${width} ${height}" width="100%" height="auto" xmlns="http://www.w3.org/2000/svg" style="overflow:visible;">
        ${gridLines.join("")}
        ${gridLabels.join("")}
        ${zeroLine}
        ${bars.join("")}
        ${xLabels.join("")}
        <text x="${width / 2}" y="${height - 32}" text-anchor="middle" fill="var(--text-secondary)" font-size="11">P&L Range</text>
        <text x="12" y="${padding.top + chartH / 2}" text-anchor="middle" fill="var(--text-secondary)" font-size="11" transform="rotate(-90, 12, ${padding.top + chartH / 2})">Trade Count</text>
      </svg>
    `
    this.element.innerHTML = svg
  }

  renderScatter() {
    const points = this.pointsValue
    const padding = { top: 20, right: 20, bottom: 50, left: 60 }
    const width = 800
    const height = 400
    const chartW = width - padding.left - padding.right
    const chartH = height - padding.top - padding.bottom

    const xs = points.map(p => parseFloat(p.x))
    const ys = points.map(p => parseFloat(p.y))
    const minX = Math.min(...xs)
    const maxX = Math.max(...xs)
    const minY = Math.min(...ys)
    const maxY = Math.max(...ys)
    const rangeX = maxX - minX || 1
    const rangeY = maxY - minY || 1

    const scaleX = (v) => padding.left + ((v - minX) / rangeX) * chartW
    const scaleY = (v) => padding.top + chartH - ((v - minY) / rangeY) * chartH

    // Grid
    const gridLines = []
    const gridLabels = []
    for (let i = 0; i <= 5; i++) {
      const yVal = minY + (rangeY * i / 5)
      const y = scaleY(yVal)
      gridLines.push(`<line x1="${padding.left}" y1="${y}" x2="${width - padding.right}" y2="${y}" stroke="var(--border)" stroke-width="1" stroke-dasharray="4,4"/>`)
      gridLabels.push(`<text x="${padding.left - 8}" y="${y + 4}" text-anchor="end" fill="var(--text-secondary)" font-size="11">${this.formatNumber(yVal)}</text>`)
    }
    for (let i = 0; i <= 5; i++) {
      const xVal = minX + (rangeX * i / 5)
      const x = scaleX(xVal)
      gridLabels.push(`<text x="${x}" y="${height - 5}" text-anchor="middle" fill="var(--text-secondary)" font-size="11">${this.formatNumber(xVal)}</text>`)
    }

    // Zero lines
    let zeroLines = ""
    if (minX < 0 && maxX > 0) {
      zeroLines += `<line x1="${scaleX(0)}" y1="${padding.top}" x2="${scaleX(0)}" y2="${padding.top + chartH}" stroke="var(--text-secondary)" stroke-width="1" opacity="0.4"/>`
    }
    if (minY < 0 && maxY > 0) {
      zeroLines += `<line x1="${padding.left}" y1="${scaleY(0)}" x2="${width - padding.right}" y2="${scaleY(0)}" stroke="var(--text-secondary)" stroke-width="1" opacity="0.4"/>`
    }

    // Dots
    const dots = points.map((p, i) => {
      const x = scaleX(parseFloat(p.x))
      const y = scaleY(parseFloat(p.y))
      const color = parseFloat(p.y) >= 0 ? "var(--positive)" : "var(--negative)"
      const label = p.label || ""
      return `<circle cx="${x}" cy="${y}" r="5" fill="${color}" opacity="0.7" stroke="${color}" stroke-width="1">
        <title>${label}${label ? ": " : ""}Risk: ${this.formatCurrency(parseFloat(p.x))}, Reward: ${this.formatCurrency(parseFloat(p.y))}</title>
      </circle>`
    })

    // Axis labels
    const xAxisLabel = `<text x="${width / 2}" y="${height - 28}" text-anchor="middle" fill="var(--text-secondary)" font-size="11">Risk (Max Drawdown)</text>`
    const yAxisLabel = `<text x="12" y="${padding.top + chartH / 2}" text-anchor="middle" fill="var(--text-secondary)" font-size="11" transform="rotate(-90, 12, ${padding.top + chartH / 2})">Reward (P&L)</text>`

    const svg = `
      <svg viewBox="0 0 ${width} ${height}" width="100%" height="auto" xmlns="http://www.w3.org/2000/svg" style="overflow:visible;">
        ${gridLines.join("")}
        ${gridLabels.join("")}
        ${zeroLines}
        ${dots.join("")}
        ${xAxisLabel}
        ${yAxisLabel}
      </svg>
    `
    this.element.innerHTML = svg
  }

  formatNumber(val) {
    if (Math.abs(val) >= 1000) {
      return (val / 1000).toFixed(1) + "k"
    }
    return val.toFixed(0)
  }

  addHoverEffects() {
    const dots = this.element.querySelectorAll(".chart-dot")
    dots.forEach(dot => {
      dot.addEventListener("mouseenter", () => { dot.setAttribute("opacity", "1") })
      dot.addEventListener("mouseleave", () => { dot.setAttribute("opacity", "0") })
    })
  }

  formatCurrency(val) {
    const sign = val >= 0 ? "+" : ""
    return `${sign}$${Math.abs(val).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
  }

  formatLabel(val) {
    if (typeof val === "string" && val.match(/^\d{4}-\d{2}-\d{2}/)) {
      const parts = val.split("-")
      return `${parts[1]}/${parts[2]}`
    }
    return String(val).substring(0, 8)
  }
}

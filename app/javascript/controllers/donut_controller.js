import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["canvas", "legend"]
  static values = { data: Array, size: { type: Number, default: 200 }, hole: { type: Number, default: 0.6 } }

  connect() {
    this.render()
    this.resizeObserver = new ResizeObserver(() => this.render())
    this.resizeObserver.observe(this.element)
  }

  disconnect() {
    this.resizeObserver?.disconnect()
  }

  render() {
    if (!this.hasCanvasTarget || !this.dataValue.length) return

    const data = this.dataValue
      .filter(d => d.value > 0)
      .sort((a, b) => b.value - a.value)

    if (data.length === 0) return

    const total = data.reduce((s, d) => s + d.value, 0)
    const size = this.sizeValue
    const cx = size / 2
    const cy = size / 2
    const outerR = size / 2 - 4
    const innerR = outerR * this.holeValue

    const colors = [
      "#1a73e8", "#ea8600", "#0d904f", "#d93025", "#6366f1",
      "#f59e0b", "#06b6d4", "#8b5cf6", "#ec4899", "#14b8a6",
      "#f97316", "#64748b"
    ]

    let paths = ""
    let angle = -Math.PI / 2

    data.forEach((item, i) => {
      const sliceAngle = (item.value / total) * Math.PI * 2
      const color = item.color || colors[i % colors.length]
      const midAngle = angle + sliceAngle / 2

      if (data.length === 1) {
        // Full circle
        paths += `<circle cx="${cx}" cy="${cy}" r="${outerR}" fill="${color}" />`
        paths += `<circle cx="${cx}" cy="${cy}" r="${innerR}" fill="var(--surface)" />`
      } else {
        const x1 = cx + outerR * Math.cos(angle)
        const y1 = cy + outerR * Math.sin(angle)
        const x2 = cx + outerR * Math.cos(angle + sliceAngle)
        const y2 = cy + outerR * Math.sin(angle + sliceAngle)
        const ix1 = cx + innerR * Math.cos(angle + sliceAngle)
        const iy1 = cy + innerR * Math.sin(angle + sliceAngle)
        const ix2 = cx + innerR * Math.cos(angle)
        const iy2 = cy + innerR * Math.sin(angle)
        const large = sliceAngle > Math.PI ? 1 : 0

        paths += `<path d="M${x1},${y1} A${outerR},${outerR} 0 ${large} 1 ${x2},${y2} L${ix1},${iy1} A${innerR},${innerR} 0 ${large} 0 ${ix2},${iy2} Z" fill="${color}" class="donut-slice" data-index="${i}" />`
      }

      angle += sliceAngle
    })

    this.canvasTarget.innerHTML = `<svg viewBox="0 0 ${size} ${size}" style="width: 100%; max-width: ${size}px;">${paths}</svg>`

    if (this.hasLegendTarget) {
      this.legendTarget.innerHTML = data.map((item, i) => {
        const color = item.color || colors[i % colors.length]
        const pct = ((item.value / total) * 100).toFixed(1)
        return `<div class="donut-legend-item">
          <span class="donut-legend-dot" style="background: ${color}"></span>
          <span class="donut-legend-label">${item.label}</span>
          <span class="donut-legend-value">${pct}%</span>
        </div>`
      }).join("")
    }
  }
}

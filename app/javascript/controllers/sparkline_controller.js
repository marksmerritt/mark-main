import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    data: Array,
    width: { type: Number, default: 100 },
    height: { type: Number, default: 28 },
    color: { type: String, default: "var(--primary)" },
    fill: { type: Boolean, default: false }
  }

  connect() {
    this.render()
  }

  render() {
    const data = this.dataValue
    if (!data || data.length < 2) return

    const w = this.widthValue
    const h = this.heightValue
    const pad = 2
    const min = Math.min(...data)
    const max = Math.max(...data)
    const range = max - min || 1

    const points = data.map((v, i) => {
      const x = pad + (i / (data.length - 1)) * (w - pad * 2)
      const y = h - pad - ((v - min) / range) * (h - pad * 2)
      return `${x.toFixed(1)},${y.toFixed(1)}`
    })

    const polyline = points.join(" ")
    const last = data[data.length - 1]
    const prev = data[data.length - 2]
    const dotColor = last >= prev ? "var(--positive)" : "var(--negative)"
    const lastPt = points[points.length - 1].split(",")

    let fillPath = ""
    if (this.fillValue) {
      fillPath = `<polygon points="${points.join(" ")} ${w - pad},${h - pad} ${pad},${h - pad}" fill="${this.colorValue}" opacity="0.1" />`
    }

    this.element.innerHTML = `<svg viewBox="0 0 ${w} ${h}" style="width: ${w}px; height: ${h}px;">
      ${fillPath}
      <polyline points="${polyline}" fill="none" stroke="${this.colorValue}" stroke-width="1.5" stroke-linejoin="round" stroke-linecap="round" />
      <circle cx="${lastPt[0]}" cy="${lastPt[1]}" r="2.5" fill="${dotColor}" />
    </svg>`
  }
}

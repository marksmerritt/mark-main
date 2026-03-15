import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "sizeSlider", "sizeLabel",
    "removeSlider", "removeLabel",
    "stopSlider", "stopLabel",
    "winnersToggle", "winnersLabel",
    "chart", "statsBody",
    "removedCard", "removedBody"
  ]

  static values = {
    trades: Array,
    baseline: Object
  }

  connect() {
    this.loadFromLocalStorage()
    this.simulate()
  }

  loadFromLocalStorage() {
    const savedSize = localStorage.getItem("eq_sim_size")
    const savedRemove = localStorage.getItem("eq_sim_remove")
    const savedStop = localStorage.getItem("eq_sim_stop")
    const savedWinners = localStorage.getItem("eq_sim_winners")

    if (savedSize && this.hasSizeSliderTarget) this.sizeSliderTarget.value = savedSize
    if (savedRemove && this.hasRemoveSliderTarget) this.removeSliderTarget.value = savedRemove
    if (savedStop && this.hasStopSliderTarget) this.stopSliderTarget.value = savedStop
    if (savedWinners && this.hasWinnersToggleTarget) this.winnersToggleTarget.checked = savedWinners === "true"
  }

  saveToLocalStorage() {
    if (this.hasSizeSliderTarget) localStorage.setItem("eq_sim_size", this.sizeSliderTarget.value)
    if (this.hasRemoveSliderTarget) localStorage.setItem("eq_sim_remove", this.removeSliderTarget.value)
    if (this.hasStopSliderTarget) localStorage.setItem("eq_sim_stop", this.stopSliderTarget.value)
    if (this.hasWinnersToggleTarget) localStorage.setItem("eq_sim_winners", this.winnersToggleTarget.checked)
  }

  resetParams() {
    if (this.hasSizeSliderTarget) this.sizeSliderTarget.value = 1.0
    if (this.hasRemoveSliderTarget) this.removeSliderTarget.value = 0
    if (this.hasStopSliderTarget) this.stopSliderTarget.value = 0
    if (this.hasWinnersToggleTarget) this.winnersToggleTarget.checked = false
    localStorage.removeItem("eq_sim_size")
    localStorage.removeItem("eq_sim_remove")
    localStorage.removeItem("eq_sim_stop")
    localStorage.removeItem("eq_sim_winners")
    this.simulate()
  }

  simulate() {
    const trades = this.tradesValue
    if (!trades || trades.length === 0) return

    // Read params
    const sizeMultiplier = this.hasSizeSliderTarget ? parseFloat(this.sizeSliderTarget.value) : 1.0
    const removeWorst = this.hasRemoveSliderTarget ? parseInt(this.removeSliderTarget.value) : 0
    const stopLossPct = this.hasStopSliderTarget ? parseFloat(this.stopSliderTarget.value) : 0
    const onlyWinners = this.hasWinnersToggleTarget ? this.winnersToggleTarget.checked : false

    // Update labels
    if (this.hasSizeLabelTarget) this.sizeLabelTarget.textContent = `${sizeMultiplier.toFixed(1)}x`
    if (this.hasRemoveLabelTarget) this.removeLabelTarget.textContent = `${removeWorst}`
    if (this.hasStopLabelTarget) this.stopLabelTarget.textContent = stopLossPct > 0 ? `${stopLossPct}%` : "Off"
    if (this.hasWinnersLabelTarget) this.winnersLabelTarget.textContent = onlyWinners ? "On" : "Off"

    this.saveToLocalStorage()

    // Build original equity curve
    const originalCurve = [0]
    let cumOriginal = 0
    for (const t of trades) {
      cumOriginal += t.pnl
      originalCurve.push(parseFloat(cumOriginal.toFixed(2)))
    }

    // Step 1: Determine which trades to remove (worst N by P&L)
    const tradesCopy = trades.map((t, i) => ({ ...t, originalIndex: i }))
    const sortedByPnl = [...tradesCopy].sort((a, b) => a.pnl - b.pnl)
    const removedTrades = []
    const removedIndices = new Set()

    // Remove worst N trades
    const actualRemove = Math.min(removeWorst, sortedByPnl.length)
    for (let i = 0; i < actualRemove; i++) {
      removedIndices.add(sortedByPnl[i].originalIndex)
      removedTrades.push(sortedByPnl[i])
    }

    // Step 2: Filter and transform remaining trades
    const simTrades = []
    for (let i = 0; i < trades.length; i++) {
      if (removedIndices.has(i)) continue

      let pnl = trades[i].pnl

      // Only winners filter
      if (onlyWinners && pnl <= 0) continue

      // Apply stop-loss cap: if loss exceeds stopLossPct of entry_price * quantity, cap it
      if (stopLossPct > 0 && pnl < 0) {
        const entryValue = trades[i].entry_price * trades[i].quantity
        if (entryValue > 0) {
          const maxLoss = -(entryValue * stopLossPct / 100)
          if (pnl < maxLoss) {
            pnl = maxLoss
          }
        }
      }

      // Apply position size multiplier
      pnl = pnl * sizeMultiplier

      simTrades.push({
        ...trades[i],
        simPnl: parseFloat(pnl.toFixed(2))
      })
    }

    // Build simulated equity curve
    const simCurve = [0]
    let cumSim = 0
    for (const t of simTrades) {
      cumSim += t.simPnl
      simCurve.push(parseFloat(cumSim.toFixed(2)))
    }

    // Compute stats
    const simPnls = simTrades.map(t => t.simPnl)
    const simStats = this.computeStats(simPnls)
    const baseline = this.baselineValue

    // Draw chart
    this.drawChart(originalCurve, simCurve)

    // Update stats table
    this.updateStats(baseline, simStats)

    // Update removed trades table
    this.updateRemovedTrades(removedTrades, onlyWinners, trades)
  }

  computeStats(pnls) {
    if (pnls.length === 0) {
      return { total_pnl: 0, trade_count: 0, win_rate: 0, max_drawdown: 0, best_trade: 0, worst_trade: 0, sharpe: 0 }
    }

    const total = pnls.reduce((s, p) => s + p, 0)
    const wins = pnls.filter(p => p > 0)
    const winRate = pnls.length > 0 ? (wins.length / pnls.length * 100) : 0

    // Max drawdown
    let peak = 0, maxDd = 0, running = 0
    for (const p of pnls) {
      running += p
      if (running > peak) peak = running
      const dd = peak - running
      if (dd > maxDd) maxDd = dd
    }

    // Sharpe-like ratio
    let sharpe = 0
    if (pnls.length >= 2) {
      const mean = total / pnls.length
      const variance = pnls.reduce((s, p) => s + (p - mean) ** 2, 0) / pnls.length
      const stdDev = Math.sqrt(variance)
      if (stdDev > 0) sharpe = mean / stdDev
    }

    return {
      total_pnl: parseFloat(total.toFixed(2)),
      trade_count: pnls.length,
      win_rate: parseFloat(winRate.toFixed(1)),
      max_drawdown: parseFloat(maxDd.toFixed(2)),
      best_trade: parseFloat(Math.max(...pnls).toFixed(2)),
      worst_trade: parseFloat(Math.min(...pnls).toFixed(2)),
      sharpe: parseFloat(sharpe.toFixed(2))
    }
  }

  drawChart(originalCurve, simCurve) {
    if (!this.hasChartTarget) return

    const padding = { top: 25, right: 25, bottom: 40, left: 70 }
    const width = 800
    const height = 320
    const chartW = width - padding.left - padding.right
    const chartH = height - padding.top - padding.bottom

    // Combine both curves to find global min/max
    const allVals = [...originalCurve, ...simCurve]
    const minY = Math.min(0, ...allVals)
    const maxY = Math.max(0, ...allVals)
    const rangeY = maxY - minY || 1

    const maxLen = Math.max(originalCurve.length, simCurve.length)

    const scaleX = (i, len) => padding.left + (i / (len - 1 || 1)) * chartW
    const scaleY = (v) => padding.top + chartH - ((v - minY) / rangeY) * chartH

    // Grid lines
    const gridLines = []
    const gridLabels = []
    const steps = 5
    for (let i = 0; i <= steps; i++) {
      const val = minY + (rangeY * i / steps)
      const y = scaleY(val)
      gridLines.push(`<line x1="${padding.left}" y1="${y}" x2="${width - padding.right}" y2="${y}" stroke="var(--border)" stroke-width="1" stroke-dasharray="4,4"/>`)
      gridLabels.push(`<text x="${padding.left - 8}" y="${y + 4}" text-anchor="end" fill="var(--text-secondary)" font-size="11">${this.formatCurrency(val)}</text>`)
    }

    // Zero line
    const zeroY = scaleY(0)

    // Original curve polyline
    const origPoints = originalCurve.map((v, i) => `${scaleX(i, originalCurve.length).toFixed(1)},${scaleY(v).toFixed(1)}`).join(" ")
    // Original area
    const origArea = [
      `${scaleX(0, originalCurve.length).toFixed(1)},${scaleY(0).toFixed(1)}`,
      ...originalCurve.map((v, i) => `${scaleX(i, originalCurve.length).toFixed(1)},${scaleY(v).toFixed(1)}`),
      `${scaleX(originalCurve.length - 1, originalCurve.length).toFixed(1)},${scaleY(0).toFixed(1)}`
    ].join(" ")

    // Simulated curve polyline
    const simPoints = simCurve.map((v, i) => `${scaleX(i, simCurve.length).toFixed(1)},${scaleY(v).toFixed(1)}`).join(" ")
    // Simulated area
    const simArea = [
      `${scaleX(0, simCurve.length).toFixed(1)},${scaleY(0).toFixed(1)}`,
      ...simCurve.map((v, i) => `${scaleX(i, simCurve.length).toFixed(1)},${scaleY(v).toFixed(1)}`),
      `${scaleX(simCurve.length - 1, simCurve.length).toFixed(1)},${scaleY(0).toFixed(1)}`
    ].join(" ")

    // X-axis labels (trade numbers)
    const xLabels = []
    const labelCount = Math.min(8, maxLen)
    for (let i = 0; i < labelCount; i++) {
      const idx = Math.round(i * (maxLen - 1) / (labelCount - 1 || 1))
      const x = scaleX(idx, maxLen)
      xLabels.push(`<text x="${x}" y="${height - 5}" text-anchor="middle" fill="var(--text-secondary)" font-size="11">Trade ${idx}</text>`)
    }

    // End value labels
    const origEndVal = originalCurve[originalCurve.length - 1]
    const simEndVal = simCurve[simCurve.length - 1]
    const origEndX = scaleX(originalCurve.length - 1, originalCurve.length)
    const simEndX = scaleX(simCurve.length - 1, simCurve.length)

    const svg = `
      <svg viewBox="0 0 ${width} ${height}" width="100%" height="auto" xmlns="http://www.w3.org/2000/svg" style="overflow:visible;">
        ${gridLines.join("")}
        ${gridLabels.join("")}
        <line x1="${padding.left}" y1="${zeroY}" x2="${width - padding.right}" y2="${zeroY}" stroke="var(--text-secondary)" stroke-width="1" opacity="0.4"/>

        <!-- Original curve -->
        <polygon points="${origArea}" fill="var(--primary)" opacity="0.08"/>
        <polyline points="${origPoints}" fill="none" stroke="var(--primary)" stroke-width="2" stroke-linejoin="round" stroke-linecap="round" opacity="0.6"/>

        <!-- Simulated curve -->
        <polygon points="${simArea}" fill="#6a1b9a" opacity="0.12"/>
        <polyline points="${simPoints}" fill="none" stroke="#6a1b9a" stroke-width="2.5" stroke-linejoin="round" stroke-linecap="round"/>

        <!-- End dots -->
        <circle cx="${origEndX}" cy="${scaleY(origEndVal)}" r="4" fill="var(--primary)" stroke="var(--surface)" stroke-width="2"/>
        <circle cx="${simEndX}" cy="${scaleY(simEndVal)}" r="4" fill="#6a1b9a" stroke="var(--surface)" stroke-width="2"/>

        <!-- End labels -->
        <text x="${origEndX + 8}" y="${scaleY(origEndVal) + 4}" fill="var(--primary)" font-size="10" font-weight="600">${this.formatCurrency(origEndVal)}</text>
        <text x="${simEndX + 8}" y="${scaleY(simEndVal) + 4}" fill="#6a1b9a" font-size="10" font-weight="600">${this.formatCurrency(simEndVal)}</text>

        ${xLabels.join("")}
      </svg>
    `
    this.chartTarget.innerHTML = svg
  }

  updateStats(baseline, simStats) {
    if (!this.hasStatsBodyTarget) return

    const metrics = [
      { label: "Total P&L", origKey: "total_pnl", simKey: "total_pnl", format: "currency" },
      { label: "Trade Count", origKey: "trade_count", simKey: "trade_count", format: "number" },
      { label: "Win Rate", origKey: "win_rate", simKey: "win_rate", format: "percent" },
      { label: "Max Drawdown", origKey: "max_drawdown", simKey: "max_drawdown", format: "currency", invert: true },
      { label: "Best Trade", origKey: "best_trade", simKey: "best_trade", format: "currency" },
      { label: "Worst Trade", origKey: "worst_trade", simKey: "worst_trade", format: "currency" },
      { label: "Sharpe Ratio", origKey: "sharpe", simKey: "sharpe", format: "decimal" }
    ]

    let html = ""
    for (const m of metrics) {
      const origVal = baseline[m.origKey] || 0
      const simVal = simStats[m.simKey] || 0
      const diff = simVal - origVal
      const improved = m.invert ? diff < 0 : diff > 0
      const neutral = Math.abs(diff) < 0.01

      const origStr = this.formatValue(origVal, m.format)
      const simStr = this.formatValue(simVal, m.format)
      const diffStr = this.formatDiff(diff, m.format)
      const diffColor = neutral ? "var(--text-secondary)" : (improved ? "var(--positive)" : "var(--negative)")
      const diffIcon = neutral ? "" : (improved ? "arrow_upward" : "arrow_downward")

      html += `
        <tr style="border-bottom: 1px solid var(--border);">
          <td style="padding: 0.75rem 1rem; font-weight: 500;">${m.label}</td>
          <td style="padding: 0.75rem 0.5rem; text-align: right; font-variant-numeric: tabular-nums;">${origStr}</td>
          <td style="padding: 0.75rem 0.5rem; text-align: right; font-weight: 600; font-variant-numeric: tabular-nums;">${simStr}</td>
          <td style="padding: 0.75rem 1rem; text-align: right; color: ${diffColor}; font-variant-numeric: tabular-nums;">
            ${diffIcon ? `<span class="material-icons-outlined" style="font-size: 0.75rem; vertical-align: -1px;">${diffIcon}</span>` : ""}
            ${diffStr}
          </td>
        </tr>
      `
    }

    this.statsBodyTarget.innerHTML = html
  }

  updateRemovedTrades(removedTrades, onlyWinners, allTrades) {
    if (!this.hasRemovedCardTarget || !this.hasRemovedBodyTarget) return

    // Also collect trades removed by only-winners filter
    const extraRemoved = []
    if (onlyWinners) {
      for (let i = 0; i < allTrades.length; i++) {
        if (allTrades[i].pnl <= 0 && !removedTrades.find(r => r.originalIndex === i)) {
          extraRemoved.push({ ...allTrades[i], originalIndex: i })
        }
      }
    }

    const allRemoved = [...removedTrades, ...extraRemoved]

    if (allRemoved.length === 0) {
      this.removedCardTarget.style.display = "none"
      return
    }

    this.removedCardTarget.style.display = "block"
    allRemoved.sort((a, b) => a.pnl - b.pnl)

    let html = ""
    allRemoved.forEach((t, i) => {
      const color = t.pnl >= 0 ? "var(--positive)" : "var(--negative)"
      html += `
        <tr style="border-bottom: 1px solid var(--border);">
          <td style="padding: 0.5rem 1rem; color: var(--text-secondary);">${i + 1}</td>
          <td style="padding: 0.5rem; font-weight: 500;">${t.symbol || "—"}</td>
          <td style="padding: 0.5rem; color: var(--text-secondary);">${t.date || "—"}</td>
          <td style="padding: 0.5rem 1rem; text-align: right; font-weight: 600; color: ${color};">${this.formatCurrency(t.pnl)}</td>
        </tr>
      `
    })

    this.removedBodyTarget.innerHTML = html
  }

  formatCurrency(val) {
    const sign = val >= 0 ? "" : "-"
    return `${sign}$${Math.abs(val).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
  }

  formatValue(val, format) {
    switch (format) {
      case "currency": return this.formatCurrency(val)
      case "percent": return `${val.toFixed(1)}%`
      case "number": return val.toLocaleString()
      case "decimal": return val.toFixed(2)
      default: return String(val)
    }
  }

  formatDiff(diff, format) {
    const sign = diff >= 0 ? "+" : ""
    switch (format) {
      case "currency": return `${sign}${this.formatCurrency(diff)}`
      case "percent": return `${sign}${diff.toFixed(1)}%`
      case "number": return `${sign}${diff.toLocaleString()}`
      case "decimal": return `${sign}${diff.toFixed(2)}`
      default: return `${sign}${diff}`
    }
  }
}

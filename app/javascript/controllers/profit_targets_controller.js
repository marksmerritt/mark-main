import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "dailyInput", "weeklyInput", "monthlyInput", "saveStatus",
    "dailyBar", "dailyPct", "dailyTargetLabel",
    "weeklyBar", "weeklyPct", "weeklyTargetLabel",
    "monthlyBar", "monthlyPct", "monthlyTargetLabel",
    "hitRateRing", "hitRatePct", "hitDaysCount", "missDaysCount",
    "hitRateFooter", "chart", "targetLine"
  ]

  static values = {
    suggestedDaily: Number,
    suggestedWeekly: Number,
    suggestedMonthly: Number,
    todayPnl: Number,
    weekPnl: Number,
    monthPnl: Number,
    dailyPnlJson: String,
    defaultDailyTarget: Number
  }

  connect() {
    this.loadFromLocalStorage()
    this.updateDisplay()
  }

  loadFromLocalStorage() {
    const savedDaily = localStorage.getItem("profit_target_daily")
    const savedWeekly = localStorage.getItem("profit_target_weekly")
    const savedMonthly = localStorage.getItem("profit_target_monthly")

    if (savedDaily) this.dailyInputTarget.value = savedDaily
    if (savedWeekly) this.weeklyInputTarget.value = savedWeekly
    if (savedMonthly) this.monthlyInputTarget.value = savedMonthly
  }

  saveTargets() {
    const daily = this.dailyInputTarget.value
    const weekly = this.weeklyInputTarget.value
    const monthly = this.monthlyInputTarget.value

    localStorage.setItem("profit_target_daily", daily)
    localStorage.setItem("profit_target_weekly", weekly)
    localStorage.setItem("profit_target_monthly", monthly)

    this.updateDisplay()

    if (this.hasSaveStatusTarget) {
      this.saveStatusTarget.textContent = "Targets saved!"
      setTimeout(() => { this.saveStatusTarget.textContent = "" }, 3000)
    }
  }

  updateTargets() {
    this.updateDisplay()
  }

  updateDisplay() {
    const dailyTarget = parseFloat(this.dailyInputTarget.value) || 0
    const weeklyTarget = parseFloat(this.weeklyInputTarget.value) || 0
    const monthlyTarget = parseFloat(this.monthlyInputTarget.value) || 0

    const todayPnl = this.todayPnlValue
    const weekPnl = this.weekPnlValue
    const monthPnl = this.monthPnlValue

    // Update daily progress
    this.updateProgress(
      todayPnl, dailyTarget,
      this.dailyBarTarget, this.dailyPctTarget, this.dailyTargetLabelTarget,
      "#2196f3"
    )

    // Update weekly progress
    this.updateProgress(
      weekPnl, weeklyTarget,
      this.weeklyBarTarget, this.weeklyPctTarget, this.weeklyTargetLabelTarget,
      "#9c27b0"
    )

    // Update monthly progress
    this.updateProgress(
      monthPnl, monthlyTarget,
      this.monthlyBarTarget, this.monthlyPctTarget, this.monthlyTargetLabelTarget,
      "#e65100"
    )

    // Update hit rate stats
    this.updateHitRate(dailyTarget)
  }

  updateProgress(current, target, barTarget, pctTarget, labelTarget, baseColor) {
    const pct = target > 0 ? Math.max(0, Math.round(current / target * 100)) : 0
    const clampedPct = Math.min(pct, 100)
    const color = pct >= 100 ? "var(--positive)" : baseColor

    barTarget.style.width = `${clampedPct}%`
    barTarget.style.background = color
    pctTarget.textContent = `${pct}%`
    labelTarget.textContent = this.formatCurrency(target)
  }

  updateHitRate(dailyTarget) {
    try {
      const dailyPnl = JSON.parse(this.dailyPnlJsonValue || "{}")
      const values = Object.values(dailyPnl).map(v => parseFloat(v))
      const totalDays = values.length
      const hitDays = values.filter(v => v >= dailyTarget).length
      const missDays = totalDays - hitDays
      const hitRate = totalDays > 0 ? (hitDays / totalDays * 100).toFixed(1) : "0.0"

      if (this.hasHitRateRingTarget) {
        this.hitRateRingTarget.setAttribute("stroke-dasharray", `${hitRate}, 100`)
      }
      if (this.hasHitRatePctTarget) {
        this.hitRatePctTarget.textContent = `${hitRate}%`
      }
      if (this.hasHitDaysCountTarget) {
        this.hitDaysCountTarget.textContent = hitDays
      }
      if (this.hasMissDaysCountTarget) {
        this.missDaysCountTarget.textContent = missDays
      }
      if (this.hasHitRateFooterTarget) {
        this.hitRateFooterTarget.textContent = `${hitRate}%`
      }
    } catch (e) {
      // silently fail if JSON parsing fails
    }
  }

  formatCurrency(value) {
    return new Intl.NumberFormat("en-US", {
      style: "currency",
      currency: "USD",
      minimumFractionDigits: 0,
      maximumFractionDigits: 0
    }).format(value)
  }
}

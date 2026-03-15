import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["pnlTarget", "winRateTarget", "tradeCountTarget",
                     "pnlBar", "winRateBar", "tradeCountBar",
                     "pnlLabel", "winRateLabel", "tradeCountLabel",
                     "editor"]
  static values = { pnl: Number, winRate: Number, tradeCount: Number }

  connect() {
    this.loadGoals()
    this.updateDisplay()
  }

  loadGoals() {
    const saved = localStorage.getItem("dashboard_goals")
    if (saved) {
      const goals = JSON.parse(saved)
      this.pnlGoal = goals.pnl || 10000
      this.winRateGoal = goals.winRate || 60
      this.tradeCountGoal = goals.tradeCount || 100
    } else {
      this.pnlGoal = 10000
      this.winRateGoal = 60
      this.tradeCountGoal = 100
    }
  }

  saveGoals() {
    localStorage.setItem("dashboard_goals", JSON.stringify({
      pnl: this.pnlGoal,
      winRate: this.winRateGoal,
      tradeCount: this.tradeCountGoal
    }))
  }

  toggleEditor() {
    if (this.hasEditorTarget) {
      this.editorTarget.classList.toggle("hidden")
      if (!this.editorTarget.classList.contains("hidden")) {
        this.pnlTargetTarget.value = this.pnlGoal
        this.winRateTargetTarget.value = this.winRateGoal
        this.tradeCountTargetTarget.value = this.tradeCountGoal
      }
    }
  }

  apply() {
    this.pnlGoal = parseFloat(this.pnlTargetTarget.value) || 10000
    this.winRateGoal = parseFloat(this.winRateTargetTarget.value) || 60
    this.tradeCountGoal = parseFloat(this.tradeCountTargetTarget.value) || 100
    this.saveGoals()
    this.updateDisplay()
    this.editorTarget.classList.add("hidden")
  }

  reset() {
    this.pnlGoal = 10000
    this.winRateGoal = 60
    this.tradeCountGoal = 100
    localStorage.removeItem("dashboard_goals")
    this.updateDisplay()
    this.editorTarget.classList.add("hidden")
  }

  updateDisplay() {
    const pnl = this.pnlValue
    const winRate = this.winRateValue
    const tradeCount = this.tradeCountValue

    this.updateGoalBar(this.pnlBarTarget, this.pnlLabelTarget, pnl, this.pnlGoal, true)
    this.updateGoalBar(this.winRateBarTarget, this.winRateLabelTarget, winRate, this.winRateGoal, false)
    this.updateGoalBar(this.tradeCountBarTarget, this.tradeCountLabelTarget, tradeCount, this.tradeCountGoal, false)
  }

  updateGoalBar(barTarget, labelTarget, current, goal, isCurrency) {
    const pct = Math.min(Math.max((current / goal) * 100, 0), 100)
    const fill = barTarget.querySelector(".goal-bar-fill")
    if (fill) {
      fill.style.width = `${pct}%`
      fill.className = "goal-bar-fill"
      if (pct >= 100) fill.classList.add("goal-bar-fill-complete")
      else if (pct >= 50) fill.classList.add("goal-bar-fill-on-track")
      else fill.classList.add("goal-bar-fill-behind")
    }
    if (isCurrency) {
      labelTarget.textContent = `$${current.toLocaleString(undefined, {minimumFractionDigits: 2, maximumFractionDigits: 2})} / $${goal.toLocaleString()}`
    } else {
      const suffix = labelTarget.dataset.suffix || ""
      labelTarget.textContent = `${current}${suffix} / ${goal}${suffix}`
    }
  }
}

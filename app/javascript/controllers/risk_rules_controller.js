import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["summaryBadge", "safeCount", "warningCount", "breachedCount", "rulesGrid", "pauseBanner"]

  static values = {
    metrics: String
  }

  connect() {
    this.defaultRules = {
      max_daily_loss: 500,
      max_trades: 10,
      max_position: 10000,
      max_consec_losses: 3,
      max_open: 5,
      min_rr: 2.0,
      max_pct_account: 5.0
    }

    this.ruleConfig = [
      { id: "max_daily_loss", metricKey: "today_pnl", useAbsNeg: true },
      { id: "max_trades", metricKey: "today_trade_count" },
      { id: "max_position", metricKey: "max_position_value" },
      { id: "max_consec_losses", metricKey: "consecutive_losses_today" },
      { id: "max_open", metricKey: "open_position_count" },
      { id: "min_rr", metricKey: "avg_rr_ratio", higherIsBetter: true },
      { id: "max_pct_account", metricKey: "max_pct_of_account" }
    ]

    this.rules = this.loadRules()
    this.metrics = JSON.parse(this.metricsValue || "{}")
    this.paused = localStorage.getItem("risk_rules_paused") === "true"

    this.applyStoredLimits()
    this.evaluate()

    if (this.paused && this.hasPauseBannerTarget) {
      this.pauseBannerTarget.classList.remove("hidden")
    }
  }

  loadRules() {
    try {
      const stored = localStorage.getItem("risk_rules")
      if (stored) {
        return { ...this.defaultRules, ...JSON.parse(stored) }
      }
    } catch (e) {
      // use defaults
    }
    return { ...this.defaultRules }
  }

  saveRules() {
    localStorage.setItem("risk_rules", JSON.stringify(this.rules))
  }

  applyStoredLimits() {
    // Update all inline limit inputs with stored values
    Object.keys(this.rules).forEach(ruleId => {
      const card = this.element.querySelector(`[data-rule-id="${ruleId}"]`)
      if (!card) return
      const input = card.querySelector("input[type='number']")
      if (input) {
        input.value = this.rules[ruleId]
      }
    })
  }

  updateRule(event) {
    const ruleId = event.params?.rule || event.target.dataset.riskRulesRuleParam
    const value = parseFloat(event.target.value) || 0
    if (ruleId && this.rules.hasOwnProperty(ruleId)) {
      this.rules[ruleId] = value
      this.saveRules()
      this.evaluate()
    }
  }

  resetDefaults() {
    this.rules = { ...this.defaultRules }
    localStorage.removeItem("risk_rules")
    this.applyStoredLimits()
    this.evaluate()
  }

  pauseTrading() {
    this.paused = !this.paused
    localStorage.setItem("risk_rules_paused", this.paused.toString())
    if (this.hasPauseBannerTarget) {
      this.pauseBannerTarget.classList.toggle("hidden", !this.paused)
    }
  }

  evaluate() {
    const m = this.metrics
    let safeCount = 0
    let warningCount = 0
    let breachedCount = 0

    this.ruleConfig.forEach(cfg => {
      const limit = this.rules[cfg.id]
      let current

      if (cfg.useAbsNeg) {
        const val = m[cfg.metricKey] || 0
        current = val < 0 ? Math.abs(val) : 0
      } else {
        current = m[cfg.metricKey] || 0
      }

      let status
      if (cfg.higherIsBetter) {
        if (current >= limit) {
          status = "safe"
        } else if (current >= limit * 0.6) {
          status = "warning"
        } else {
          status = "breached"
        }
      } else {
        const ratio = limit > 0 ? current / limit : 0
        if (ratio > 1) {
          status = "breached"
        } else if (ratio > 0.6) {
          status = "warning"
        } else {
          status = "safe"
        }
      }

      if (status === "safe") safeCount++
      else if (status === "warning") warningCount++
      else breachedCount++

      this.updateRuleCard(cfg.id, current, limit, status, cfg.higherIsBetter)
    })

    if (this.hasSafeCountTarget) this.safeCountTarget.textContent = safeCount
    if (this.hasWarningCountTarget) this.warningCountTarget.textContent = warningCount
    if (this.hasBreachedCountTarget) this.breachedCountTarget.textContent = breachedCount
  }

  updateRuleCard(ruleId, current, limit, status, higherIsBetter) {
    const card = this.element.querySelector(`[data-rule-id="${ruleId}"]`)
    if (!card) return

    const statusColors = { safe: "var(--positive)", warning: "#f9a825", breached: "var(--negative)" }
    const statusIcons = { safe: "check_circle", warning: "warning", breached: "dangerous" }
    const color = statusColors[status]

    // Update border color
    card.style.borderLeftColor = color

    // Update status icon (the icon on the right side of the header)
    const icons = card.querySelectorAll(".material-icons-outlined")
    if (icons.length >= 2) {
      // First icon is the rule icon, second is the status icon
      const statusEl = icons[1]
      statusEl.textContent = statusIcons[status]
      statusEl.style.color = color
    }

    // Update the rule icon color too
    if (icons.length >= 1) {
      icons[0].style.color = color
    }

    // Update current value color
    const valueSpan = card.querySelector("[style*='font-size: 1.25rem']")
    if (valueSpan) {
      valueSpan.style.color = color
    }

    // Update bar fill
    const barFill = card.querySelector("[style*='border-radius: 3px; transition']")
    if (barFill) {
      let pct
      if (higherIsBetter) {
        pct = limit > 0 ? Math.min((current / limit) * 100, 100) : 0
      } else {
        pct = limit > 0 ? Math.min((current / limit) * 100, 100) : 0
      }
      barFill.style.width = `${pct}%`
      barFill.style.background = color
    }
  }
}

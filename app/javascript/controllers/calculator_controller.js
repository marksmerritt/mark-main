import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "accountSize", "riskPercent", "entryPrice", "stopLoss",
    "takeProfit", "commission",
    "preview", "previewBody",
    "previewShares", "previewRisk", "previewRatio", "previewCost"
  ]

  connect() {
    this.timeout = null
  }

  disconnect() {
    if (this.timeout) clearTimeout(this.timeout)
  }

  preview() {
    if (this.timeout) clearTimeout(this.timeout)
    this.timeout = setTimeout(() => this.calculate(), 150)
  }

  calculate() {
    const accountSize = parseFloat(this.accountSizeTarget.value)
    const riskPercent = parseFloat(this.riskPercentTarget.value)
    const entryPrice = parseFloat(this.entryPriceTarget.value)
    const stopLoss = parseFloat(this.stopLossTarget.value)
    const takeProfit = parseFloat(this.takeProfitTarget.value) || null
    const commission = parseFloat(this.commissionTarget.value) || 0

    if (!accountSize || !riskPercent || !entryPrice || !stopLoss) {
      this.hidePreview()
      return
    }

    const riskPerShare = Math.abs(entryPrice - stopLoss)
    if (riskPerShare === 0) {
      this.hidePreview()
      return
    }

    const riskAmount = accountSize * (riskPercent / 100)
    const shares = Math.floor(riskAmount / (riskPerShare + commission))

    if (shares <= 0) {
      this.hidePreview()
      return
    }

    const totalCost = shares * entryPrice
    let ratioText = "\u2014"

    if (takeProfit) {
      const rewardPerShare = Math.abs(takeProfit - entryPrice)
      const ratio = riskPerShare > 0 ? (rewardPerShare / riskPerShare).toFixed(2) : "\u2014"
      ratioText = `1 : ${ratio}`
    }

    this.previewSharesTarget.textContent = `${shares} shares`
    this.previewRiskTarget.textContent = this.formatCurrency(riskAmount)
    this.previewRatioTarget.textContent = ratioText
    this.previewCostTarget.textContent = this.formatCurrency(totalCost)

    this.showPreview()
  }

  showPreview() {
    this.previewTarget.style.display = ""
    this.previewBodyTarget.style.display = ""
  }

  hidePreview() {
    if (!this.hasPreviewTarget) return
    this.previewBodyTarget.style.display = "none"
  }

  formatCurrency(value) {
    return new Intl.NumberFormat("en-US", {
      style: "currency",
      currency: "USD"
    }).format(value)
  }
}

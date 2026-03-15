import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["prompt", "contextBar"]

  static values = {
    todayTrades: { type: Number, default: 0 },
    todayPnl: { type: Number, default: 0 },
    todayWins: { type: Number, default: 0 },
    todayLosses: { type: Number, default: 0 },
    todaySymbols: { type: Array, default: [] },
    winRate: { type: Number, default: 0 },
    currentStreak: { type: Number, default: 0 },
    streakType: { type: String, default: "" },
    bestSymbol: { type: String, default: "" },
    bestPnl: { type: Number, default: 0 },
    worstSymbol: { type: String, default: "" },
    worstPnl: { type: Number, default: 0 }
  }

  static basePrompts = {
    content: [
      "What was the most significant trade you made today and why?",
      "Describe your emotional state during the trading session.",
      "What surprised you about the market today?",
      "Which of your setups worked best today? Why?",
      "Did you deviate from your plan? What triggered the deviation?",
      "Rate your discipline today from 1-10. What influenced the score?",
      "What pattern did you notice in price action today?",
      "How did pre-market preparation help (or hurt) your trading?"
    ],
    market_conditions: [
      "Was the market trending, ranging, or choppy today?",
      "Which sectors led or lagged today?",
      "Were there any significant news events affecting the market?",
      "How was overall volume compared to the average?",
      "Describe the VIX / volatility environment.",
      "Were key support/resistance levels respected today?"
    ],
    plan: [
      "What setups are you watching for tomorrow?",
      "What is your maximum risk for the day?",
      "Which symbols are on your focus list?",
      "What are the key levels you need to watch?",
      "Are there any economic events to be aware of?",
      "What is your primary strategy for tomorrow's session?"
    ],
    review: [
      "Did you follow your trading plan? Grade yourself A-F.",
      "What is one thing you would do differently?",
      "Were your position sizes appropriate for the setups?",
      "Did you exit trades at the right time? Too early or too late?",
      "What was your best decision today? Worst decision?",
      "What lesson will you carry into tomorrow?"
    ]
  }

  connect() {
    this.showPrompts()
    this.renderContextBar()
  }

  getSmartPrompts() {
    const prompts = {
      content: [...this.constructor.basePrompts.content],
      market_conditions: [...this.constructor.basePrompts.market_conditions],
      plan: [...this.constructor.basePrompts.plan],
      review: [...this.constructor.basePrompts.review]
    }

    const trades = this.todayTradesValue
    const pnl = this.todayPnlValue
    const wins = this.todayWinsValue
    const losses = this.todayLossesValue
    const symbols = this.todaySymbolsValue
    const streak = this.currentStreakValue
    const streakType = this.streakTypeValue

    if (trades === 0) {
      // No trades today
      prompts.content.unshift(
        "You haven't traded today. What kept you on the sidelines?",
        "Was not trading today a deliberate decision or did you miss opportunities?"
      )
      prompts.plan.unshift(
        "Since you didn't trade today, what are you looking for tomorrow?",
        "Use this down time to review your playbook. Which setups need refinement?"
      )
    } else if (pnl > 0) {
      // Green day
      prompts.content.unshift(
        `You're up $${pnl.toFixed(2)} today across ${trades} trade${trades > 1 ? 's' : ''}. What went right?`,
        `${wins} winning trade${wins > 1 ? 's' : ''} today. Was it skill, setup quality, or market conditions?`
      )
      if (this.bestSymbolValue) {
        prompts.content.unshift(
          `${this.bestSymbolValue} was your best trade (+$${this.bestPnlValue.toFixed(2)}). Walk through your decision process.`
        )
      }
      prompts.review.unshift(
        "Great day! But were you over-leveraged, or was your sizing appropriate?",
        "Would you take the same trades tomorrow? What made today's setups compelling?"
      )
    } else if (pnl < 0) {
      // Red day
      prompts.content.unshift(
        `Down $${Math.abs(pnl).toFixed(2)} today. What would you change if you could replay the session?`,
        `${losses} losing trade${losses > 1 ? 's' : ''} today. Were these valid setups that didn't work, or forced trades?`
      )
      if (this.worstSymbolValue) {
        prompts.content.unshift(
          `${this.worstSymbolValue} was your worst trade ($${this.worstPnlValue.toFixed(2)}). Did you follow your stop?`
        )
      }
      prompts.review.unshift(
        "Red days happen. What's the one adjustment that would have improved today?",
        "Did you cut losses quickly or let them run? Be honest with yourself."
      )
      prompts.plan.unshift(
        "After a losing day, what will you do differently tomorrow?",
        "Should you reduce size tomorrow or trade your normal plan?"
      )
    }

    // Streak-specific prompts
    if (streak >= 3 && streakType === "win") {
      prompts.content.unshift(
        `You're on a ${streak}-trade win streak. Are you staying disciplined or getting overconfident?`
      )
      prompts.plan.unshift(
        "Hot streaks can breed complacency. What's your plan to stay sharp?"
      )
    } else if (streak >= 3 && streakType === "loss") {
      prompts.content.unshift(
        `You're in a ${streak}-trade losing streak. Is this a setup issue, sizing issue, or market issue?`
      )
      prompts.plan.unshift(
        "Consider reducing size or taking a break. What's your recovery plan?",
        "After a losing streak, are you revenge trading or staying process-focused?"
      )
    }

    // Symbol-specific prompts
    if (symbols.length > 0) {
      const symList = symbols.slice(0, 3).join(", ")
      prompts.market_conditions.unshift(
        `How did ${symList} behave relative to the broader market today?`
      )
    }

    if (symbols.length > 4) {
      prompts.review.unshift(
        `You traded ${symbols.length} different symbols. Was this overtrading or valid diversification?`
      )
    }

    return prompts
  }

  showPrompts() {
    const prompts = this.getSmartPrompts()
    this.promptTargets.forEach(el => {
      const field = el.dataset.field
      const fieldPrompts = prompts[field]
      if (fieldPrompts && fieldPrompts.length > 0) {
        // Show the first (most contextual) prompt
        el.textContent = fieldPrompts[0]
        el.style.display = ""
      }
    })
  }

  refresh() {
    const prompts = this.getSmartPrompts()
    this.promptTargets.forEach(el => {
      const field = el.dataset.field
      const fieldPrompts = prompts[field]
      if (fieldPrompts && fieldPrompts.length > 0) {
        const randomIndex = Math.floor(Math.random() * fieldPrompts.length)
        el.textContent = fieldPrompts[randomIndex]
      }
    })
  }

  renderContextBar() {
    if (!this.hasContextBarTarget) return
    const trades = this.todayTradesValue
    if (trades === 0) {
      this.contextBarTarget.innerHTML = `
        <div style="display: flex; align-items: center; gap: 0.5rem; padding: 0.75rem 1rem; background: var(--bg); border-radius: var(--radius); margin-bottom: 1rem; font-size: 0.8125rem;">
          <span class="material-icons-outlined" style="font-size: 1.125rem; color: var(--text-secondary);">info</span>
          <span>No trades recorded today. Prompts are tailored to non-trading days.</span>
        </div>
      `
      return
    }

    const pnl = this.todayPnlValue
    const wins = this.todayWinsValue
    const losses = this.todayLossesValue
    const pnlColor = pnl >= 0 ? 'var(--positive)' : 'var(--negative)'
    const pnlSign = pnl >= 0 ? '+' : ''

    this.contextBarTarget.innerHTML = `
      <div style="display: flex; align-items: center; gap: 1.5rem; padding: 0.75rem 1rem; background: var(--bg); border-radius: var(--radius); margin-bottom: 1rem; font-size: 0.8125rem; flex-wrap: wrap;">
        <span style="display: flex; align-items: center; gap: 0.375rem;">
          <span class="material-icons-outlined" style="font-size: 1rem; color: ${pnlColor};">${pnl >= 0 ? 'trending_up' : 'trending_down'}</span>
          <strong>Today:</strong>
          <span style="color: ${pnlColor}; font-weight: 600;">${pnlSign}$${Math.abs(pnl).toFixed(2)}</span>
        </span>
        <span>${trades} trade${trades > 1 ? 's' : ''}</span>
        <span style="color: var(--positive);">${wins}W</span>
        <span style="color: var(--negative);">${losses}L</span>
        <span style="color: var(--text-secondary); font-size: 0.75rem;">Prompts tailored to your session</span>
      </div>
    `
  }
}

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["content", "marketConditions", "plan", "review", "menu"]

  templates = {
    "Pre-Market": {
      content: "## Pre-Market Analysis\n\n**Key Levels:**\n- Support: \n- Resistance: \n\n**Watchlist:**\n1. \n2. \n3. \n\n**Key News/Events:**\n- ",
      market_conditions: "**Overnight Action:**\n\n**Futures:**\n\n**Key Sectors:**\n",
      plan: "**Strategy for today:**\n\n**Max risk budget:** $\n**Max trades:** \n\n**Rules to follow:**\n1. Wait for market to establish direction\n2. Only trade A+ setups\n3. Cut losers quickly",
      review: ""
    },
    "End of Day": {
      content: "## Daily Review\n\n**Trades taken:** \n**Win/Loss:** \n**Net P&L:** $\n\n**What went well:**\n- \n\n**What could improve:**\n- \n\n**Emotions during the day:**\n",
      market_conditions: "**Market direction:** \n**Volatility:** Low / Normal / High\n**Sector leaders:** \n**Sector laggards:** ",
      plan: "",
      review: "**Did I follow my plan?** Yes / No\n**Discipline score (1-10):** \n**Key lesson learned:**\n\n**Action items for tomorrow:**\n1. \n2. "
    },
    "Weekly Review": {
      content: "## Weekly Review\n\n**Week of:** \n\n**Total P&L:** $\n**Win Rate:** %\n**Best Trade:** \n**Worst Trade:** \n\n**What patterns am I seeing?**\n\n**Am I following my playbooks?**\n",
      market_conditions: "**Weekly market summary:**\n\n**Key events this week:**\n\n**Sector rotation notes:**\n",
      plan: "**Goals for next week:**\n1. \n2. \n3. \n\n**Setups to watch:**\n",
      review: "**Weekly scorecard:**\n- Discipline: /10\n- Risk Management: /10\n- Execution: /10\n- Journaling: /10\n\n**Key takeaway:**\n"
    },
    "Trade Breakdown": {
      content: "## Trade Breakdown\n\n**Symbol:** \n**Side:** Long / Short\n**Setup:** \n\n**Entry Rationale:**\n\n**Exit Rationale:**\n\n**Screenshots:**\n",
      market_conditions: "**Market context at time of trade:**\n\n**Sector context:**\n",
      plan: "**Original plan:**\n- Entry: $\n- Stop: $\n- Target: $\n- R:R: \n\n**Actual execution:**\n- Entry: $\n- Exit: $",
      review: "**What I did well:**\n\n**What I'd do differently:**\n\n**Grade (A-F):** \n"
    }
  }

  toggleMenu() {
    if (this.hasMenuTarget) {
      this.menuTarget.classList.toggle("hidden")
    }
  }

  apply(event) {
    const name = event.currentTarget.dataset.template
    const template = this.templates[name]
    if (!template) return

    // Only fill empty fields
    if (this.hasContentTarget && !this.contentTarget.value.trim()) {
      this.contentTarget.value = template.content
    }
    if (this.hasMarketConditionsTarget && !this.marketConditionsTarget.value.trim()) {
      this.marketConditionsTarget.value = template.market_conditions
    }
    if (this.hasPlanTarget && !this.planTarget.value.trim()) {
      this.planTarget.value = template.plan
    }
    if (this.hasReviewTarget && !this.reviewTarget.value.trim()) {
      this.reviewTarget.value = template.review
    }

    this.menuTarget.classList.add("hidden")
  }
}

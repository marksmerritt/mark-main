import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["modal", "input", "results"]

  connect() {
    this.handleKeydown = this.handleKeydown.bind(this)
    document.addEventListener("keydown", this.handleKeydown)
    this.selectedIndex = 0
    this.commands = this.buildCommands()
  }

  disconnect() {
    document.removeEventListener("keydown", this.handleKeydown)
  }

  handleKeydown(event) {
    // Cmd+K or Ctrl+K to open
    if ((event.metaKey || event.ctrlKey) && event.key === "k") {
      event.preventDefault()
      this.toggle()
      return
    }

    if (!this.isOpen()) return

    switch (event.key) {
      case "Escape":
        event.preventDefault()
        this.close()
        break
      case "ArrowDown":
        event.preventDefault()
        this.moveSelection(1)
        break
      case "ArrowUp":
        event.preventDefault()
        this.moveSelection(-1)
        break
      case "Enter":
        event.preventDefault()
        this.executeSelected()
        break
    }
  }

  toggle() {
    if (this.isOpen()) {
      this.close()
    } else {
      this.open()
    }
  }

  open() {
    this.modalTarget.classList.remove("hidden")
    this.inputTarget.value = ""
    this.selectedIndex = 0
    this.render(this.commands)
    requestAnimationFrame(() => this.inputTarget.focus())
  }

  close() {
    this.modalTarget.classList.add("hidden")
    this.inputTarget.value = ""
  }

  isOpen() {
    return !this.modalTarget.classList.contains("hidden")
  }

  backdropClick(event) {
    if (event.target === this.modalTarget) this.close()
  }

  filter() {
    const query = this.inputTarget.value.trim().toLowerCase()
    if (!query) {
      this.selectedIndex = 0
      this.render(this.commands)
      return
    }

    const scored = this.commands.map(cmd => {
      const score = this.fuzzyScore(query, cmd.searchText)
      return { ...cmd, score }
    }).filter(cmd => cmd.score > 0)
      .sort((a, b) => b.score - a.score)

    this.selectedIndex = 0
    this.render(scored)
  }

  fuzzyScore(query, target) {
    const t = target.toLowerCase()
    // Exact substring match scores highest
    if (t.includes(query)) return 100 + (query.length / t.length * 50)
    // Word-start match
    const words = t.split(/\s+/)
    let wordScore = 0
    const queryWords = query.split(/\s+/)
    for (const qw of queryWords) {
      if (words.some(w => w.startsWith(qw))) wordScore += 30
      else if (words.some(w => w.includes(qw))) wordScore += 15
    }
    if (wordScore > 0) return wordScore
    // Fuzzy character match
    let qi = 0
    for (let i = 0; i < t.length && qi < query.length; i++) {
      if (t[i] === query[qi]) qi++
    }
    return qi === query.length ? 10 : 0
  }

  moveSelection(delta) {
    const items = this.resultsTarget.querySelectorAll(".cmd-item")
    if (!items.length) return
    this.selectedIndex = Math.max(0, Math.min(items.length - 1, this.selectedIndex + delta))
    this.updateSelection(items)
  }

  updateSelection(items) {
    items.forEach((el, i) => {
      el.classList.toggle("cmd-item-active", i === this.selectedIndex)
    })
    items[this.selectedIndex]?.scrollIntoView({ block: "nearest" })
  }

  executeSelected() {
    const items = this.resultsTarget.querySelectorAll(".cmd-item")
    const selected = items[this.selectedIndex]
    if (selected) {
      const url = selected.dataset.url
      const action = selected.dataset.action
      this.close()
      if (action) {
        this.executeAction(action)
      } else if (url) {
        window.Turbo.visit(url)
      }
    }
  }

  executeAction(action) {
    switch (action) {
      case "quick-trade":
        document.querySelector("[data-controller='quick-trade'] [data-quick-trade-target='modal']")?.classList.remove("hidden")
        break
      case "quick-journal":
        document.querySelector("[data-controller='quick-journal'] [data-quick-journal-target='modal']")?.classList.remove("hidden")
        break
      case "quick-capture":
        document.querySelector("[data-controller='quick-capture'] [data-quick-capture-target='modal']")?.classList.remove("hidden")
        break
      case "quick-expense":
        document.querySelector("[data-controller='quick-expense'] [data-quick-expense-target='modal']")?.classList.remove("hidden")
        break
      case "toggle-theme":
        document.querySelector("[data-controller='theme'] .theme-toggle")?.click()
        break
      case "shortcuts":
        document.dispatchEvent(new KeyboardEvent("keydown", { key: "?" }))
        break
    }
  }

  clickItem(event) {
    const item = event.currentTarget
    const url = item.dataset.url
    const action = item.dataset.cmdAction
    this.close()
    if (action) {
      this.executeAction(action)
    } else if (url) {
      window.Turbo.visit(url)
    }
  }

  render(items) {
    if (!items.length) {
      this.resultsTarget.innerHTML = '<div class="cmd-empty">No results found</div>'
      return
    }

    // Group by section
    const groups = {}
    items.forEach(item => {
      if (!groups[item.section]) groups[item.section] = []
      groups[item.section].push(item)
    })

    let html = ""
    for (const [section, sectionItems] of Object.entries(groups)) {
      html += `<div class="cmd-section"><span class="cmd-section-label">${section}</span></div>`
      sectionItems.forEach(item => {
        html += `<div class="cmd-item" data-url="${item.url || ''}" data-cmd-action="${item.action || ''}" data-action="click->command-palette#clickItem">
          <span class="material-icons-outlined cmd-item-icon">${item.icon}</span>
          <div class="cmd-item-text">
            <span class="cmd-item-title">${item.title}</span>
            ${item.subtitle ? `<span class="cmd-item-subtitle">${item.subtitle}</span>` : ''}
          </div>
          ${item.shortcut ? `<kbd class="cmd-kbd">${item.shortcut}</kbd>` : ''}
        </div>`
      })
    }

    this.resultsTarget.innerHTML = html
    this.updateSelection(this.resultsTarget.querySelectorAll(".cmd-item"))
  }

  buildCommands() {
    return [
      // Quick Actions
      { section: "Actions", title: "New Trade", subtitle: "Log a new trade", icon: "add_circle_outline", url: "/trades/new", shortcut: "N", searchText: "new trade add create log" },
      { section: "Actions", title: "Quick Add Trade", subtitle: "Quick trade entry dialog", icon: "bolt", action: "quick-trade", shortcut: "A", searchText: "quick add trade fast" },
      { section: "Actions", title: "New Journal Entry", subtitle: "Write a journal entry", icon: "auto_stories", url: "/journal_entries/new", shortcut: "J", searchText: "new journal entry write" },
      { section: "Actions", title: "Quick Journal", subtitle: "Quick journal dialog", icon: "edit_note", action: "quick-journal", shortcut: "Q", searchText: "quick journal fast" },
      { section: "Actions", title: "New Note", subtitle: "Create a new note", icon: "note_add", url: "/notes/new", shortcut: "M", searchText: "new note create write" },
      { section: "Actions", title: "New Trade Plan", subtitle: "Create a trade plan", icon: "assignment", url: "/trade_plans/new", searchText: "new trade plan create strategy" },
      { section: "Actions", title: "New Watchlist", subtitle: "Create a watchlist", icon: "visibility", url: "/watchlists/new", searchText: "new watchlist create" },
      { section: "Actions", title: "Quick Note", subtitle: "Capture a quick note", icon: "note_add", action: "quick-capture", searchText: "quick note capture idea" },
      { section: "Actions", title: "Quick Expense", subtitle: "Log an expense quickly", icon: "payments", action: "quick-expense", shortcut: "X", searchText: "quick expense log spend transaction" },

      // Navigation - Trading
      { section: "Trading", title: "Dashboard", subtitle: "Home dashboard", icon: "dashboard", url: "/", shortcut: "H", searchText: "home dashboard overview main" },
      { section: "Trading", title: "Trades", subtitle: "All trades", icon: "show_chart", url: "/trades", shortcut: "T", searchText: "trades list all" },
      { section: "Trading", title: "Trade Plans", subtitle: "Manage trade plans", icon: "assignment", url: "/trade_plans", shortcut: "P", searchText: "trade plans strategy" },
      { section: "Trading", title: "Watchlists", subtitle: "Market watchlists", icon: "visibility", url: "/watchlists", shortcut: "W", searchText: "watchlists market watch" },
      { section: "Trading", title: "Playbooks", subtitle: "Trading playbooks", icon: "menu_book", url: "/playbooks", shortcut: "B", searchText: "playbooks strategies" },
      { section: "Trading", title: "Position Calculator", subtitle: "Size your positions", icon: "calculate", url: "/position_calculator", shortcut: "C", searchText: "position calculator size risk" },
      { section: "Trading", title: "Journal", subtitle: "Trading journal entries", icon: "auto_stories", url: "/journal_entries", searchText: "journal entries diary" },
      { section: "Trading", title: "Journal Calendar", subtitle: "Calendar view of journal", icon: "calendar_month", url: "/journal_entries/calendar", searchText: "journal calendar view" },
      { section: "Trading", title: "Tags", subtitle: "Manage trade tags", icon: "label", url: "/tags", searchText: "tags labels categories" },
      { section: "Trading", title: "Trade Review", subtitle: "Review unreviewed trades", icon: "rate_review", url: "/trades/review", shortcut: "V", searchText: "review trades unreviewed queue" },
      { section: "Trading", title: "Compare Trades", subtitle: "Side-by-side trade comparison", icon: "compare_arrows", url: "/comparison", searchText: "compare trades side by side" },
      { section: "Trading", title: "Export Data", subtitle: "Export trades, journal, notes", icon: "download", url: "/data_export", searchText: "export data download csv json" },

      // Reports - Trading
      { section: "Reports", title: "Reports Overview", subtitle: "Trading performance summary", icon: "analytics", url: "/reports/overview", shortcut: "R", searchText: "reports overview performance summary" },
      { section: "Reports", title: "By Symbol", subtitle: "Performance by ticker", icon: "category", url: "/reports/by_symbol", searchText: "reports symbol ticker performance" },
      { section: "Reports", title: "By Tag", subtitle: "Performance by tag", icon: "label", url: "/reports/by_tag", searchText: "reports tag label performance" },
      { section: "Reports", title: "Equity Curve", subtitle: "Cumulative P&L chart", icon: "trending_up", url: "/reports/equity_curve", shortcut: "E", searchText: "equity curve chart pnl cumulative" },
      { section: "Reports", title: "Risk Analysis", subtitle: "Risk metrics and drawdown", icon: "warning", url: "/reports/risk_analysis", searchText: "risk analysis drawdown max" },
      { section: "Reports", title: "Risk/Reward", subtitle: "R:R ratio analysis", icon: "balance", url: "/reports/risk_reward", searchText: "risk reward ratio analysis" },
      { section: "Reports", title: "By Time", subtitle: "Performance by time of day", icon: "schedule", url: "/reports/by_time", searchText: "time of day hour performance" },
      { section: "Reports", title: "By Duration", subtitle: "Performance by hold time", icon: "timelapse", url: "/reports/by_duration", searchText: "duration hold time performance" },
      { section: "Reports", title: "Heatmap", subtitle: "Trading activity heatmap", icon: "grid_on", url: "/reports/heatmap", searchText: "heatmap calendar activity" },
      { section: "Reports", title: "Monte Carlo", subtitle: "Monte Carlo simulation", icon: "casino", url: "/reports/monte_carlo", searchText: "monte carlo simulation probability" },
      { section: "Reports", title: "Distribution", subtitle: "P&L distribution", icon: "bar_chart", url: "/reports/distribution", searchText: "distribution histogram pnl" },
      { section: "Reports", title: "Weekly Summary", subtitle: "Weekly trading review", icon: "date_range", url: "/reports/weekly_summary", searchText: "weekly summary review" },
      { section: "Reports", title: "Scorecard", subtitle: "Trading scorecard", icon: "score", url: "/reports/scorecard", shortcut: "D", searchText: "scorecard grade performance rating" },
      { section: "Reports", title: "Setup Analysis", subtitle: "Performance by setup", icon: "build", url: "/reports/setup_analysis", searchText: "setup analysis strategy" },
      { section: "Reports", title: "Correlation", subtitle: "Factor correlations", icon: "hub", url: "/reports/correlation", searchText: "correlation factors" },
      { section: "Reports", title: "Streaks", subtitle: "Win/loss streak analysis", icon: "local_fire_department", url: "/reports/streak_analysis", searchText: "streaks win loss consecutive" },
      { section: "Reports", title: "Monthly P&L", subtitle: "Month-by-month performance", icon: "calendar_today", url: "/reports/monthly_performance", searchText: "monthly pnl performance" },
      { section: "Reports", title: "Review Analytics", subtitle: "Trade review statistics", icon: "insights", url: "/trades/review_stats", searchText: "review analytics statistics" },
      { section: "Reports", title: "Period Comparison", subtitle: "Compare two time periods", icon: "compare_arrows", url: "/reports/period_comparison", searchText: "period comparison compare time range" },
      { section: "Reports", title: "Execution Quality", subtitle: "Analyze trade execution discipline", icon: "fact_check", url: "/reports/execution_quality", searchText: "execution quality discipline plan adherence grade" },
      { section: "Reports", title: "Mood Analytics", subtitle: "Emotional state impact on trading", icon: "psychology", url: "/reports/mood_analytics", searchText: "mood analytics emotional state feelings psychology calm anxious" },

      // Notes
      { section: "Notes", title: "All Notes", subtitle: "Browse all notes", icon: "description", url: "/notes", searchText: "notes all browse" },
      { section: "Notes", title: "Pinboard", subtitle: "Pinned notes", icon: "push_pin", url: "/notes/pinboard", searchText: "pinboard pinned notes" },
      { section: "Notes", title: "Notebooks", subtitle: "Manage notebooks", icon: "folder", url: "/note_notebooks", searchText: "notebooks folders organize" },
      { section: "Notes", title: "Templates", subtitle: "Note templates", icon: "content_copy", url: "/note_templates", searchText: "templates note create" },
      { section: "Notes", title: "Reminders", subtitle: "Note reminders", icon: "notifications", url: "/reminders", searchText: "reminders alerts notifications" },
      { section: "Notes", title: "Trash", subtitle: "Deleted notes", icon: "delete", url: "/trash", searchText: "trash deleted notes recover" },
      { section: "Notes", title: "Search Notes", subtitle: "Search within notes", icon: "search", url: "/notes_search/search", searchText: "search notes find" },

      // Budget
      { section: "Budget", title: "Budget Dashboard", subtitle: "Budget overview", icon: "account_balance", url: "/budget", shortcut: "G", searchText: "budget dashboard overview" },
      { section: "Budget", title: "Budget Calendar", subtitle: "Calendar view", icon: "calendar_month", url: "/budget/calendar", searchText: "budget calendar view" },
      { section: "Budget", title: "Paycheck Allocator", subtitle: "Allocate income to categories", icon: "payments", url: "/budget/allocate", searchText: "paycheck allocator income allocate" },
      { section: "Budget", title: "Budgets", subtitle: "Monthly budgets", icon: "account_balance_wallet", url: "/budget/budgets", searchText: "budgets monthly manage" },
      { section: "Budget", title: "Transactions", subtitle: "All transactions", icon: "receipt_long", url: "/budget/transactions", searchText: "transactions expenses income" },
      { section: "Budget", title: "Sinking Funds", subtitle: "Savings fund tracking", icon: "savings", url: "/budget/funds", searchText: "sinking funds savings" },
      { section: "Budget", title: "Debt Accounts", subtitle: "Debt payoff tracking", icon: "credit_card", url: "/budget/debt_accounts", searchText: "debt accounts credit payoff" },
      { section: "Budget", title: "Snowball Plan", subtitle: "Debt snowball strategy", icon: "ac_unit", url: "/budget/debt_accounts/snowball", searchText: "snowball debt payoff strategy" },
      { section: "Budget", title: "Avalanche Plan", subtitle: "Debt avalanche strategy", icon: "terrain", url: "/budget/debt_accounts/avalanche", searchText: "avalanche debt payoff strategy" },
      { section: "Budget", title: "Compare Payoff Plans", subtitle: "Snowball vs Avalanche side by side", icon: "compare", url: "/budget/debt_accounts/compare_plans", searchText: "compare snowball avalanche payoff debt strategy" },
      { section: "Budget", title: "Recurring", subtitle: "Recurring transactions", icon: "autorenew", url: "/budget/recurring", searchText: "recurring bills subscriptions" },
      { section: "Budget", title: "Bill Calendar", subtitle: "Upcoming bills calendar", icon: "event", url: "/budget/recurring/calendar", searchText: "bill calendar upcoming due" },
      { section: "Budget", title: "Goals", subtitle: "Financial goals", icon: "flag", url: "/budget/goals", searchText: "goals savings financial targets" },
      { section: "Budget", title: "Challenges", subtitle: "Savings challenges", icon: "emoji_events", url: "/budget/challenges", searchText: "challenges savings gamify" },
      { section: "Budget", title: "Spending Rules", subtitle: "Auto-categorization rules", icon: "rule", url: "/budget/spending_rules", searchText: "spending rules auto categorize" },
      { section: "Budget", title: "Alerts", subtitle: "Budget alerts", icon: "notification_important", url: "/budget/alerts", searchText: "alerts budget notifications" },

      // Budget Reports
      { section: "Budget Reports", title: "Spending Report", subtitle: "Spending by category", icon: "pie_chart", url: "/budget/reports/spending", searchText: "spending report category breakdown" },
      { section: "Budget Reports", title: "Net Worth", subtitle: "Net worth tracker", icon: "account_balance", url: "/budget/reports/net_worth", searchText: "net worth tracker assets liabilities" },
      { section: "Budget Reports", title: "Income vs Expenses", subtitle: "Income expense comparison", icon: "compare_arrows", url: "/budget/reports/income_vs_expenses", searchText: "income expenses comparison" },
      { section: "Budget Reports", title: "Budget Comparison", subtitle: "Budget vs actual", icon: "difference", url: "/budget/reports/comparison", searchText: "budget comparison actual variance" },
      { section: "Budget Reports", title: "Merchants", subtitle: "Spending by merchant", icon: "storefront", url: "/budget/reports/merchants", searchText: "merchants spending vendors" },
      { section: "Budget Reports", title: "Forecast", subtitle: "Spending forecast", icon: "trending_up", url: "/budget/reports/forecast", searchText: "forecast projection spending" },
      { section: "Budget Reports", title: "Insights", subtitle: "Spending insights", icon: "lightbulb", url: "/budget/reports/insights", searchText: "insights spending analysis" },
      { section: "Budget Reports", title: "Year over Year", subtitle: "Annual comparison", icon: "date_range", url: "/budget/reports/year_over_year", searchText: "year over year annual comparison" },
      { section: "Budget Reports", title: "Monthly Digest", subtitle: "Monthly budget digest", icon: "summarize", url: "/budget/reports/digest", searchText: "monthly digest summary" },

      // Digest
      { section: "Utility", title: "Weekly Digest", subtitle: "Cross-system weekly review", icon: "summarize", url: "/digest", searchText: "weekly digest review summary" },

      // Analysis Tools
      { section: "Analysis", title: "Performance Benchmarks", subtitle: "Compare to industry standards", icon: "leaderboard", url: "/performance_benchmarks", searchText: "benchmarks ranking percentile tier comparison" },
      { section: "Analysis", title: "Trend Analyzer", subtitle: "Performance and behavior trends", icon: "insights", url: "/trend_analyzer", searchText: "trends analyzer patterns rolling average" },
      { section: "Analysis", title: "Mood & Performance", subtitle: "How mood affects trading", icon: "psychology_alt", url: "/mood_performance", searchText: "mood emotions performance psychology" },
      { section: "Analysis", title: "Sizing Advisor", subtitle: "Kelly Criterion sizing", icon: "tune", url: "/sizing_advisor", searchText: "sizing advisor kelly criterion position risk" },
      { section: "Analysis", title: "Cross-Product Insights", subtitle: "How products correlate", icon: "hub", url: "/cross_product_insights", searchText: "cross product insights correlations journal spending" },
      { section: "Analysis", title: "Smart Alerts", subtitle: "Intelligent cross-product alerts", icon: "notifications_active", url: "/smart_alerts", searchText: "smart alerts warnings notifications risk" },
      { section: "Analysis", title: "Goal Tracker", subtitle: "Unified goals across products", icon: "flag", url: "/goal_tracker", searchText: "goals tracker targets milestones progress" },
      { section: "Analysis", title: "Habit Tracker", subtitle: "Daily habit discipline grid", icon: "self_improvement", url: "/habit_tracker", searchText: "habits tracker daily discipline streak" },
      { section: "Analysis", title: "Portfolio Overview", subtitle: "Total financial picture", icon: "account_balance", url: "/portfolio_overview", searchText: "portfolio overview net worth total finances" },
      { section: "Analysis", title: "Weekly Planner", subtitle: "Plan your week", icon: "date_range", url: "/weekly_planner", searchText: "weekly planner schedule calendar" },
      { section: "Analysis", title: "Strategy Builder", subtitle: "Define and backtest trading strategies", icon: "architecture", url: "/strategy_builder", searchText: "strategy builder backtest template pattern define" },
      { section: "Analysis", title: "Achievements", subtitle: "Trading badges and milestones", icon: "emoji_events", url: "/achievements", searchText: "achievements badges milestones gamification trophies" },
      { section: "Analysis", title: "Profit Targets", subtitle: "Daily/weekly/monthly P&L targets", icon: "track_changes", url: "/profit_targets", searchText: "profit targets daily weekly monthly pnl goals" },
      { section: "Analysis", title: "Drawdown Tracker", subtitle: "Track drawdowns and recovery", icon: "trending_down", url: "/drawdown_tracker", searchText: "drawdown tracker recovery peak trough risk" },
      { section: "Analysis", title: "Performance Attribution", subtitle: "P&L breakdown by dimension", icon: "pie_chart", url: "/performance_attribution", searchText: "attribution breakdown symbol side time contributor" },
      { section: "Analysis", title: "Account Health", subtitle: "Comprehensive health score", icon: "health_and_safety", url: "/account_health", searchText: "account health score wellness trading financial" },
      { section: "Analysis", title: "Journal Prompts", subtitle: "Context-aware journaling prompts", icon: "psychology", url: "/journal_prompts", searchText: "journal prompts writing reflection questions" },
      { section: "Analysis", title: "Risk Rules", subtitle: "Personal trading risk limits", icon: "gavel", url: "/risk_rules", searchText: "risk rules engine limits daily max loss position" },
      { section: "Analysis", title: "Market Session", subtitle: "Live market hours clock", icon: "schedule", url: "/market_session", searchText: "market session timer clock hours trading" },
      { section: "Analysis", title: "Trade Calendar", subtitle: "Monthly trade-by-trade calendar", icon: "calendar_month", url: "/trade_calendar", searchText: "trade calendar monthly individual daily" },
      { section: "Analysis", title: "Correlation Matrix", subtitle: "Symbol correlation heatmap", icon: "grid_view", url: "/correlation_matrix", searchText: "correlation matrix heatmap symbols diversification" },
      { section: "Analysis", title: "Win/Loss Analysis", subtitle: "What separates winners from losers", icon: "compare_arrows", url: "/win_loss_analysis", searchText: "win loss analysis comparison profile edge" },
      { section: "Analysis", title: "Spending vs Trading", subtitle: "Spending-trading correlation", icon: "sync_alt", url: "/spending_trading", searchText: "spending trading correlation budget habits" },
      { section: "Analysis", title: "Trade Templates", subtitle: "Save & reuse trade setups", icon: "content_copy", url: "/trade_templates", searchText: "trade templates setup preset reuse quick" },
      { section: "Analysis", title: "Snapshot Report", subtitle: "Printable performance snapshot", icon: "summarize", url: "/snapshot_report", searchText: "snapshot report summary print grade period" },
      { section: "Analysis", title: "Streak Calendar", subtitle: "Activity heatmap & streaks", icon: "local_fire_department", url: "/streak_calendar", searchText: "streak calendar heatmap activity consistency fire" },
      { section: "Analysis", title: "Equity Simulator", subtitle: "What-if equity curve scenarios", icon: "science", url: "/equity_simulator", searchText: "equity simulator what if position size stop loss" },
      { section: "Analysis", title: "Playbook Comparison", subtitle: "Compare playbook strategies", icon: "difference", url: "/playbook_comparison", searchText: "playbook comparison strategy performance" },
      { section: "Analysis", title: "Sizing Backtest", subtitle: "Position sizing strategies", icon: "science", url: "/sizing_backtest", searchText: "sizing backtest kelly criterion fractional position" },
      { section: "Analysis", title: "Consistency Report", subtitle: "Behavioral consistency score", icon: "verified", url: "/consistency_report", searchText: "consistency report discipline behavioral score radar" },
      { section: "Analysis", title: "Symbol Deep Dive", subtitle: "Deep analysis of one symbol", icon: "query_stats", url: "/symbol_deep_dive", searchText: "symbol deep dive ticker breakdown detail analysis" },

      // Daily
      { section: "Daily", title: "Morning Briefing", subtitle: "Start your day prepared", icon: "wb_sunny", url: "/morning_briefing", searchText: "morning briefing daily readiness score focus" },

      // Settings & Utility
      { section: "Utility", title: "Search", subtitle: "Global search", icon: "search", url: "/search", shortcut: "S", searchText: "search global find" },
      { section: "Utility", title: "Settings", subtitle: "App settings", icon: "settings", url: "/settings", searchText: "settings configuration api tokens" },
      { section: "Utility", title: "Getting Started", subtitle: "Setup guide", icon: "help_outline", url: "/getting_started", searchText: "getting started guide onboarding help" },
      { section: "Utility", title: "Toggle Dark Mode", subtitle: "Switch theme", icon: "dark_mode", action: "toggle-theme", searchText: "dark mode light theme toggle" },
      { section: "Utility", title: "Keyboard Shortcuts", subtitle: "View all shortcuts", icon: "keyboard", action: "shortcuts", shortcut: "?", searchText: "keyboard shortcuts help hotkeys" },
    ]
  }
}

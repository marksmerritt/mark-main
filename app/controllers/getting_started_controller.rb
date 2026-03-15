class GettingStartedController < ApplicationController
  def index
    @sections = build_sections
    @all_steps = @sections.flat_map { |s| s[:steps] }
    @completed = @all_steps.count { |s| s[:done] }
    @total = @all_steps.count
  end

  private

  def build_sections
    trading_connected = api_token.present?
    notes_connected = notes_api_token.present?
    budget_connected = budget_api_token.present?

    has_trades = trading_connected && begin
      result = api_client.trades(per_page: 1)
      trades = result["trades"] || result
      trades.is_a?(Array) && trades.any?
    rescue
      false
    end

    has_notes = notes_connected && begin
      result = notes_client.notes(per_page: 1)
      notes = result["notes"] || result
      notes.is_a?(Array) && notes.any?
    rescue
      false
    end

    has_budget = budget_connected && begin
      result = budget_client.budgets
      result.is_a?(Array) && result.any?
    rescue
      false
    end

    [
      {
        name: "Connect Your APIs",
        description: "Link Mark Main to your backend services to unlock all features.",
        icon: "hub",
        steps: [
          { title: "Connect Trading Journal API", desc: "Set TRADING_JOURNAL_URL and TRADING_JOURNAL_TOKEN environment variables.", done: trading_connected, action_path: settings_path, icon: "link" },
          { title: "Connect Notes API", desc: "Set NOTES_API_URL and NOTES_API_TOKEN environment variables.", done: notes_connected, action_path: settings_path, icon: "link" },
          { title: "Connect Budget API", desc: "Set BUDGET_API_URL and BUDGET_API_TOKEN environment variables.", done: budget_connected, action_path: settings_path, icon: "account_balance" }
        ]
      },
      {
        name: "Trading Journal",
        description: "Track, review, and improve your trading with data-driven insights.",
        icon: "candlestick_chart",
        steps: [
          { title: "Log your first trade", desc: "Record a trade to start tracking your performance.", done: has_trades, action_path: trading_connected ? new_trade_path : nil, icon: "add_circle_outline" },
          { title: "Write a journal entry", desc: "Reflect on your trading day to build better habits.", done: false, action_path: trading_connected ? new_journal_entry_path : nil, icon: "auto_stories" },
          { title: "Create a trade plan", desc: "Plan your next trade before entering the market.", done: false, action_path: trading_connected ? new_trade_plan_path : nil, icon: "assignment" },
          { title: "Set up your watchlist", desc: "Track symbols you're interested in trading.", done: false, action_path: trading_connected ? new_watchlist_path : nil, icon: "visibility" },
          { title: "Create a playbook", desc: "Document your trading strategies with entry, exit, and risk rules.", done: false, action_path: trading_connected ? new_playbook_path : nil, icon: "menu_book" },
          { title: "Try trade review mode", desc: "Step through closed trades one by one and grade your execution.", done: false, action_path: trading_connected ? review_trades_path : nil, icon: "rate_review" },
          { title: "Explore reports", desc: "View equity curves, risk analysis, P&L by symbol, and more.", done: false, action_path: trading_connected ? reports_overview_path : nil, icon: "assessment" }
        ]
      },
      {
        name: "Notes",
        description: "Capture research, ideas, and market observations in rich-text notes.",
        icon: "sticky_note_2",
        steps: [
          { title: "Create your first note", desc: "Start capturing ideas, research, and market observations.", done: has_notes, action_path: notes_connected ? new_note_path : nil, icon: "edit_note" },
          { title: "Organize with notebooks", desc: "Group related notes into notebooks for easy navigation.", done: false, action_path: notes_connected ? note_notebooks_path : nil, icon: "folder" },
          { title: "Pin important notes", desc: "Pin notes to your pinboard for quick access.", done: false, action_path: notes_connected ? pinboard_notes_path : nil, icon: "push_pin" },
          { title: "Set a reminder", desc: "Never forget to follow up — set reminders on important notes.", done: false, action_path: notes_connected ? reminders_path : nil, icon: "notifications" }
        ]
      },
      {
        name: "Budget",
        description: "Take control of your finances with zero-based budgeting and tracking.",
        icon: "account_balance_wallet",
        steps: [
          { title: "Create your first budget", desc: "Set up a zero-based budget to give every dollar a job.", done: has_budget, action_path: budget_connected ? new_budget_budget_path : nil, icon: "account_balance_wallet" },
          { title: "Add a transaction", desc: "Start tracking your spending by recording transactions.", done: false, action_path: budget_connected ? new_budget_transaction_path : nil, icon: "receipt_long" },
          { title: "Set up a sinking fund", desc: "Save for upcoming expenses like insurance or vacations.", done: false, action_path: budget_connected ? new_budget_fund_path : nil, icon: "savings" },
          { title: "Track a debt", desc: "Add debts to create a snowball or avalanche payoff plan.", done: false, action_path: budget_connected ? new_budget_debt_account_path : nil, icon: "credit_card" },
          { title: "Set a financial goal", desc: "Track progress toward emergency funds, down payments, and more.", done: false, action_path: budget_connected ? new_budget_goal_path : nil, icon: "flag" },
          { title: "Track recurring bills", desc: "Add subscriptions and bills so you never miss a payment.", done: false, action_path: budget_connected ? new_budget_recurring_path : nil, icon: "event_repeat" },
          { title: "View your dashboard", desc: "See your financial health score, spending breakdown, and upcoming bills.", done: false, action_path: budget_connected ? budget_dashboard_path : nil, icon: "dashboard" }
        ]
      }
    ]
  end
end

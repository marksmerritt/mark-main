class QuickSearchController < ApplicationController
  def index
    @pages = build_page_index
    @categories = @pages.map { |p| p[:category] }.uniq

    respond_to do |format|
      format.html
      format.json { render json: @pages }
    end
  rescue => e
    Rails.logger.error("QuickSearch error: #{e.message}")
    @pages ||= []
    @categories ||= []
  end

  private

  def build_page_index
    pages = []

    # ── Trading ──────────────────────────────────────────────
    pages << { name: "Dashboard", path: root_path, icon: "dashboard", description: "Home dashboard with health score, recent activity, and overview", keywords: "home main overview health score", category: "Trading" }
    pages << { name: "Trades", path: trades_path, icon: "show_chart", description: "Browse, filter, and manage all trades", keywords: "trades list positions stocks options", category: "Trading" }
    pages << { name: "New Trade", path: new_trade_path, icon: "add_circle_outline", description: "Log a new trade", keywords: "add create trade entry", category: "Trading" }
    pages << { name: "Import Trades", path: import_wizard_trades_path, icon: "upload_file", description: "Import trades from CSV", keywords: "import csv upload bulk trades", category: "Trading" }
    pages << { name: "Trade Plans", path: trade_plans_path, icon: "assignment", description: "Plan trades before entering positions", keywords: "plan strategy pre-trade setup", category: "Trading" }
    pages << { name: "Watchlists", path: watchlists_path, icon: "visibility", description: "Track symbols you are watching", keywords: "watchlist watch symbols tickers", category: "Trading" }
    pages << { name: "Playbooks", path: playbooks_path, icon: "menu_book", description: "Document trading strategies with rules", keywords: "playbook strategy rules setup", category: "Trading" }
    pages << { name: "Position Calculator", path: position_calculator_path, icon: "calculate", description: "Calculate position size and risk", keywords: "calculator position size risk shares", category: "Trading" }
    pages << { name: "Exposure", path: exposure_path, icon: "pie_chart", description: "View portfolio exposure by sector and asset", keywords: "exposure portfolio allocation sector", category: "Trading" }
    pages << { name: "Risk Dashboard", path: risk_dashboard_path, icon: "shield", description: "Monitor portfolio risk metrics", keywords: "risk dashboard drawdown var", category: "Trading" }
    pages << { name: "Position Risk", path: position_risk_path, icon: "warning", description: "Analyze risk for open positions", keywords: "position risk stop loss", category: "Trading" }
    pages << { name: "Pre-Market", path: pre_market_path, icon: "wb_sunny", description: "Pre-market preparation checklist", keywords: "pre-market morning routine prep", category: "Trading" }
    pages << { name: "Pre-Trade Checklist", path: trade_checklist_path, icon: "checklist", description: "Checklist before entering a trade", keywords: "checklist pre-trade rules discipline", category: "Trading" }
    pages << { name: "Journal", path: journal_entries_path, icon: "auto_stories", description: "Trading journal entries and reflections", keywords: "journal diary entries mood reflection", category: "Trading" }
    pages << { name: "Journal Calendar", path: calendar_journal_entries_path, icon: "calendar_month", description: "Calendar view of journal entries", keywords: "journal calendar monthly view", category: "Trading" }
    pages << { name: "Journal Templates", path: journal_templates_path, icon: "description", description: "Templates for journal entries", keywords: "journal templates preset format", category: "Trading" }
    pages << { name: "Tags", path: tags_path, icon: "label", description: "Manage trade tags and labels", keywords: "tags labels categories organize", category: "Trading" }
    pages << { name: "Milestones", path: milestones_path, icon: "emoji_events", description: "Track trading milestones and achievements", keywords: "milestones achievements goals streaks", category: "Trading" }
    pages << { name: "Activity Feed", path: trade_feed_path, icon: "rss_feed", description: "Recent trading activity feed", keywords: "feed activity recent stream", category: "Trading" }
    pages << { name: "Trade Review", path: review_trades_path, icon: "rate_review", description: "Review and grade closed trades", keywords: "review grade evaluate trades", category: "Trading" }
    pages << { name: "Trade Replay", path: trade_replay_path, icon: "replay", description: "Replay and analyze past trades", keywords: "replay review analyze past trades", category: "Trading" }
    pages << { name: "Trade Correlations", path: trade_correlations_path, icon: "bubble_chart", description: "Explore correlations between trades", keywords: "correlations scatter analysis relationships", category: "Trading" }
    pages << { name: "Symbol Comparison", path: symbol_comparison_path, icon: "compare_arrows", description: "Compare performance across symbols", keywords: "compare symbols tickers side by side", category: "Trading" }
    pages << { name: "Account Summary", path: account_summary_path, icon: "account_balance", description: "Overview of account performance", keywords: "account summary balance equity", category: "Trading" }
    pages << { name: "Journal Insights", path: journal_insights_path, icon: "psychology", description: "Insights derived from journal entries", keywords: "journal insights patterns mood analysis", category: "Trading" }
    pages << { name: "Report Card", path: trading_grades_path, icon: "grading", description: "Trading performance report card", keywords: "grades report card score evaluation", category: "Trading" }
    pages << { name: "Challenges", path: trading_challenges_path, icon: "fitness_center", description: "Trading challenges to build discipline", keywords: "challenges discipline goals trading", category: "Trading" }
    pages << { name: "Achievements", path: achievements_path, icon: "emoji_events", description: "Trading badges and milestones", keywords: "achievements badges gamification unlocks trophies", category: "Trading" }
    pages << { name: "Trading Mentor", path: trading_mentor_path, icon: "psychology", description: "AI-powered trading mentor and advice", keywords: "mentor coach advice tips trading", category: "Trading" }
    pages << { name: "Tax Estimator", path: tax_estimator_path, icon: "receipt_long", description: "Estimate taxes on trading gains", keywords: "tax estimate capital gains short long term", category: "Trading" }
    pages << { name: "Cost Analysis", path: trading_costs_path, icon: "payments", description: "Analyze commissions and trading costs", keywords: "costs commissions fees slippage", category: "Trading" }
    pages << { name: "Market Regimes", path: market_regime_path, icon: "trending_flat", description: "Identify market regime conditions", keywords: "market regime trend volatility conditions", category: "Trading" }
    pages << { name: "Edge Finder", path: edge_finder_path, icon: "gps_fixed", description: "Find your trading edge with data", keywords: "edge finder advantage statistical", category: "Trading" }
    pages << { name: "Strategy Builder", path: strategy_builder_path, icon: "architecture", description: "Define and backtest trading strategies", keywords: "strategy builder backtest template pattern", category: "Trading" }
    pages << { name: "Trade Simulator", path: trade_simulator_path, icon: "science", description: "Simulate hypothetical trade outcomes", keywords: "simulator what-if hypothetical scenarios", category: "Trading" }
    pages << { name: "Financial Pulse", path: financial_pulse_path, icon: "monitor_heart", description: "Combined financial health overview", keywords: "pulse health overview combined finances", category: "Trading" }
    pages << { name: "Profit Targets", path: profit_targets_path, icon: "track_changes", description: "Daily/weekly/monthly P&L targets and progress", keywords: "profit targets daily weekly monthly pnl goals", category: "Trading" }

    # ── Reports ──────────────────────────────────────────────
    pages << { name: "Reports Hub", path: reports_index_path, icon: "assessment", description: "Central hub for all trading reports", keywords: "reports hub index all analytics", category: "Reports" }
    pages << { name: "Overview Report", path: reports_overview_path, icon: "analytics", description: "High-level trading performance overview", keywords: "overview summary performance stats", category: "Reports" }
    pages << { name: "By Symbol", path: reports_by_symbol_path, icon: "bar_chart", description: "Performance breakdown by symbol", keywords: "symbol ticker performance breakdown", category: "Reports" }
    pages << { name: "By Tag", path: reports_by_tag_path, icon: "label", description: "Performance breakdown by tag", keywords: "tag label performance group", category: "Reports" }
    pages << { name: "Equity Curve", path: reports_equity_curve_path, icon: "show_chart", description: "Cumulative equity curve over time", keywords: "equity curve chart growth pnl", category: "Reports" }
    pages << { name: "Risk Analysis", path: reports_risk_analysis_path, icon: "security", description: "Detailed risk metrics and analysis", keywords: "risk analysis drawdown sharpe sortino", category: "Reports" }
    pages << { name: "Risk/Reward", path: reports_risk_reward_path, icon: "balance", description: "Risk-reward ratio analysis", keywords: "risk reward ratio r-multiple", category: "Reports" }
    pages << { name: "By Time", path: reports_by_time_path, icon: "schedule", description: "Performance by time of day", keywords: "time hour day performance timing", category: "Reports" }
    pages << { name: "By Duration", path: reports_by_duration_path, icon: "timer", description: "Performance by trade duration", keywords: "duration holding period length", category: "Reports" }
    pages << { name: "Heatmap", path: reports_heatmap_path, icon: "grid_on", description: "Performance heatmap by day and hour", keywords: "heatmap grid calendar performance", category: "Reports" }
    pages << { name: "Monte Carlo", path: reports_monte_carlo_path, icon: "casino", description: "Monte Carlo simulation of future outcomes", keywords: "monte carlo simulation probability forecast", category: "Reports" }
    pages << { name: "Distribution", path: reports_distribution_path, icon: "bar_chart", description: "P&L distribution analysis", keywords: "distribution histogram bell curve pnl", category: "Reports" }
    pages << { name: "Weekly Summary", path: reports_weekly_summary_path, icon: "view_week", description: "Week-by-week performance summary", keywords: "weekly summary week performance", category: "Reports" }
    pages << { name: "Scorecard", path: reports_scorecard_path, icon: "score", description: "Trading scorecard with key metrics", keywords: "scorecard metrics grades kpi", category: "Reports" }
    pages << { name: "Setup Analysis", path: reports_setup_analysis_path, icon: "build", description: "Analyze performance by trade setup", keywords: "setup analysis strategy pattern", category: "Reports" }
    pages << { name: "Correlation", path: reports_correlation_path, icon: "hub", description: "Correlation between trading metrics", keywords: "correlation matrix relationship metrics", category: "Reports" }
    pages << { name: "Streaks", path: reports_streak_analysis_path, icon: "local_fire_department", description: "Win/loss streak analysis", keywords: "streak win loss consecutive run", category: "Reports" }
    pages << { name: "Monthly P&L", path: reports_monthly_performance_path, icon: "calendar_month", description: "Month-by-month P&L breakdown", keywords: "monthly performance pnl breakdown", category: "Reports" }
    pages << { name: "P&L Calendar", path: reports_pnl_calendar_path, icon: "event", description: "Daily P&L on a calendar grid", keywords: "calendar pnl daily green red", category: "Reports" }
    pages << { name: "Period Comparison", path: reports_period_comparison_path, icon: "compare", description: "Compare performance across periods", keywords: "compare period month quarter year", category: "Reports" }
    pages << { name: "Execution Quality", path: reports_execution_quality_path, icon: "speed", description: "Measure trade execution quality", keywords: "execution quality slippage fills", category: "Reports" }
    pages << { name: "Mood Analytics", path: reports_mood_analytics_path, icon: "mood", description: "Trading performance by mood", keywords: "mood emotion sentiment performance", category: "Reports" }
    pages << { name: "Fee Analysis", path: reports_fee_analysis_path, icon: "receipt", description: "Commission and fee breakdown", keywords: "fees commissions costs breakdown", category: "Reports" }
    pages << { name: "Risk of Ruin", path: reports_risk_of_ruin_path, icon: "dangerous", description: "Probability of catastrophic drawdown", keywords: "risk ruin probability blowup", category: "Reports" }
    pages << { name: "Expectancy", path: reports_expectancy_path, icon: "trending_up", description: "Expected value per trade", keywords: "expectancy expected value edge per trade", category: "Reports" }
    pages << { name: "Discipline", path: reports_discipline_path, icon: "gavel", description: "Measure discipline and rule adherence", keywords: "discipline rules adherence consistency", category: "Reports" }
    pages << { name: "Position Sizing", path: reports_position_sizing_path, icon: "straighten", description: "Analyze position sizing effectiveness", keywords: "position sizing risk per trade", category: "Reports" }
    pages << { name: "Leaderboard", path: reports_leaderboard_path, icon: "leaderboard", description: "Performance leaderboard rankings", keywords: "leaderboard ranking top performance", category: "Reports" }
    pages << { name: "Habits", path: reports_habits_path, icon: "repeat", description: "Trading habit tracking", keywords: "habits routine consistency tracking", category: "Reports" }
    pages << { name: "Session Log", path: reports_session_log_path, icon: "list_alt", description: "Daily trading session log", keywords: "session log daily recap", category: "Reports" }
    pages << { name: "Playbook Performance", path: reports_playbook_performance_path, icon: "menu_book", description: "Performance by playbook strategy", keywords: "playbook strategy performance", category: "Reports" }
    pages << { name: "Equity Breakdown", path: reports_equity_breakdown_path, icon: "donut_large", description: "Equity breakdown by category", keywords: "equity breakdown composition", category: "Reports" }
    pages << { name: "What-If Simulator", path: reports_what_if_path, icon: "help_outline", description: "What-if scenario analysis on trades", keywords: "what if scenario hypothetical", category: "Reports" }
    pages << { name: "Review Stats", path: review_stats_trades_path, icon: "insights", description: "Statistics from trade reviews", keywords: "review stats analytics grading", category: "Reports" }

    # ── Notes ────────────────────────────────────────────────
    pages << { name: "Notes", path: notes_path, icon: "description", description: "Browse and manage all notes", keywords: "notes list browse all", category: "Notes" }
    pages << { name: "New Note", path: new_note_path, icon: "edit_note", description: "Create a new note", keywords: "add create new note write", category: "Notes" }
    pages << { name: "Pinboard", path: pinboard_notes_path, icon: "push_pin", description: "Pinned notes for quick access", keywords: "pinboard pinned important quick access", category: "Notes" }
    pages << { name: "Notebooks", path: note_notebooks_path, icon: "folder", description: "Organize notes into notebooks", keywords: "notebooks folders organize group", category: "Notes" }
    pages << { name: "Note Templates", path: note_templates_path, icon: "content_copy", description: "Reusable templates for notes", keywords: "templates preset format note", category: "Notes" }
    pages << { name: "Note Tags", path: note_tags_path, icon: "sell", description: "Manage tags for notes", keywords: "tags labels notes organize", category: "Notes" }
    pages << { name: "Reminders", path: reminders_path, icon: "notifications_active", description: "Manage note reminders", keywords: "reminders alerts due dates follow up", category: "Notes" }
    pages << { name: "Trash", path: trash_index_path, icon: "delete", description: "Deleted notes trash bin", keywords: "trash deleted restore bin", category: "Notes" }
    pages << { name: "Knowledge Graph", path: knowledge_graph_notes_path, icon: "hub", description: "Visual knowledge graph of linked notes", keywords: "knowledge graph connections links visualization", category: "Notes" }
    pages << { name: "Connections", path: note_links_path, icon: "link", description: "View and manage note connections", keywords: "links connections backlinks references", category: "Notes" }
    pages << { name: "Productivity", path: productivity_notes_path, icon: "speed", description: "Writing productivity metrics", keywords: "productivity metrics writing output", category: "Notes" }
    pages << { name: "Writing Stats", path: writing_stats_path, icon: "edit", description: "Detailed writing statistics", keywords: "writing stats words count streak", category: "Notes" }
    pages << { name: "Writing Digest", path: writing_digest_path, icon: "summarize", description: "Weekly writing activity digest", keywords: "writing digest weekly summary", category: "Notes" }
    pages << { name: "Writing Prompts", path: writing_prompts_path, icon: "lightbulb", description: "Creative writing prompts and inspiration", keywords: "prompts ideas inspiration writing", category: "Notes" }
    pages << { name: "Focus Timer", path: focus_timer_path, icon: "timer", description: "Pomodoro-style focus timer", keywords: "focus timer pomodoro concentrate", category: "Notes" }
    pages << { name: "Reading Stats", path: reading_stats_path, icon: "menu_book", description: "Track reading progress and stats", keywords: "reading stats books progress", category: "Notes" }
    pages << { name: "Flashcards", path: note_flashcards_path, icon: "school", description: "Study flashcards from your notes", keywords: "flashcards study review spaced repetition", category: "Notes" }
    pages << { name: "Note Maintenance", path: note_maintenance_path, icon: "build", description: "Stale notes and maintenance tasks", keywords: "maintenance stale cleanup orphan", category: "Notes" }
    pages << { name: "Note Search", path: notes_search_search_path, icon: "search", description: "Full-text search across notes", keywords: "search find notes text", category: "Notes" }

    # ── Budget ───────────────────────────────────────────────
    pages << { name: "Budget Dashboard", path: budget_dashboard_path, icon: "dashboard", description: "Budget overview and financial health", keywords: "budget dashboard overview finances", category: "Budget" }
    pages << { name: "Budget Calendar", path: budget_calendar_path, icon: "calendar_today", description: "Calendar view of budget activity", keywords: "budget calendar monthly spending", category: "Budget" }
    pages << { name: "Financial Calendar", path: budget_financial_calendar_path, icon: "event", description: "Upcoming bills and financial events", keywords: "financial calendar events bills due dates", category: "Budget" }
    pages << { name: "Paycheck Allocator", path: budget_allocate_path, icon: "account_balance_wallet", description: "Allocate paycheck to budget categories", keywords: "allocate paycheck income distribute", category: "Budget" }
    pages << { name: "Budgets", path: budget_budgets_path, icon: "account_balance_wallet", description: "Manage monthly budgets", keywords: "budgets monthly zero-based categories", category: "Budget" }
    pages << { name: "Transactions", path: budget_transactions_path, icon: "receipt_long", description: "View and manage transactions", keywords: "transactions spending expenses income", category: "Budget" }
    pages << { name: "New Transaction", path: new_budget_transaction_path, icon: "add_circle", description: "Record a new transaction", keywords: "add new transaction expense income", category: "Budget" }
    pages << { name: "Savings Dashboard", path: budget_savings_path, icon: "savings", description: "Savings overview and progress", keywords: "savings overview dashboard progress", category: "Budget" }
    pages << { name: "Emergency Fund", path: budget_emergency_fund_path, icon: "health_and_safety", description: "Emergency fund calculator", keywords: "emergency fund rainy day safety net", category: "Budget" }
    pages << { name: "Sinking Funds", path: budget_funds_path, icon: "savings", description: "Manage sinking funds for planned expenses", keywords: "sinking funds savings planned expenses", category: "Budget" }
    pages << { name: "Debt Accounts", path: budget_debt_accounts_path, icon: "credit_card", description: "Track debts and payoff progress", keywords: "debt accounts credit card loan balance", category: "Budget" }
    pages << { name: "Debt Freedom", path: budget_debt_freedom_path, icon: "celebration", description: "Debt freedom calculator and timeline", keywords: "debt freedom payoff date calculator", category: "Budget" }
    pages << { name: "Debt Visualizer", path: budget_debt_visualizer_path, icon: "trending_down", description: "Visualize debt payoff journey", keywords: "debt visualizer chart payoff graph", category: "Budget" }
    pages << { name: "Snowball Plan", path: snowball_budget_debt_accounts_path, icon: "ac_unit", description: "Debt snowball payoff strategy", keywords: "snowball debt smallest first payoff", category: "Budget" }
    pages << { name: "Avalanche Plan", path: avalanche_budget_debt_accounts_path, icon: "landscape", description: "Debt avalanche payoff strategy", keywords: "avalanche debt highest interest payoff", category: "Budget" }
    pages << { name: "Recurring Bills", path: budget_recurring_index_path, icon: "event_repeat", description: "Manage recurring bills and subscriptions", keywords: "recurring bills subscriptions monthly auto", category: "Budget" }
    pages << { name: "Bill Calendar", path: calendar_budget_recurring_index_path, icon: "date_range", description: "Calendar view of upcoming bills", keywords: "bill calendar due dates upcoming", category: "Budget" }
    pages << { name: "Goals", path: budget_goals_path, icon: "flag", description: "Financial goals and progress tracking", keywords: "goals targets savings milestones", category: "Budget" }
    pages << { name: "Budget Challenges", path: budget_challenges_path, icon: "emoji_events", description: "Savings and spending challenges", keywords: "challenges savings spending gamification", category: "Budget" }
    pages << { name: "Budget Tags", path: budget_tags_path, icon: "label", description: "Manage transaction tags", keywords: "tags labels categories transactions", category: "Budget" }
    pages << { name: "Spending Rules", path: budget_spending_rules_path, icon: "rule", description: "Set spending rules and alerts", keywords: "rules spending limits alerts auto", category: "Budget" }
    pages << { name: "Merchant Insights", path: budget_merchant_insights_path, icon: "store", description: "Spending patterns by merchant", keywords: "merchant insights vendor store spending", category: "Budget" }
    pages << { name: "Alerts", path: budget_alerts_path, icon: "notifications", description: "Budget alerts and notifications", keywords: "alerts notifications warnings budget", category: "Budget" }
    pages << { name: "Wellness Scorecard", path: budget_wellness_scorecard_path, icon: "favorite", description: "Financial wellness score and tips", keywords: "wellness scorecard health score financial", category: "Budget" }
    pages << { name: "Spending Report", path: budget_reports_spending_path, icon: "pie_chart", description: "Spending breakdown by category", keywords: "spending report breakdown category", category: "Budget" }
    pages << { name: "Net Worth", path: budget_reports_net_worth_path, icon: "account_balance", description: "Net worth tracking over time", keywords: "net worth assets liabilities tracking", category: "Budget" }
    pages << { name: "Income vs Expenses", path: budget_reports_income_vs_expenses_path, icon: "compare_arrows", description: "Income vs expenses comparison", keywords: "income expenses comparison surplus deficit", category: "Budget" }
    pages << { name: "Budget Comparison", path: budget_reports_comparison_path, icon: "compare", description: "Compare budgets across months", keywords: "comparison month over month budget", category: "Budget" }
    pages << { name: "Merchant Report", path: budget_reports_merchants_path, icon: "storefront", description: "Spending by merchant analysis", keywords: "merchants vendors stores spending analysis", category: "Budget" }
    pages << { name: "Budget Forecast", path: budget_reports_forecast_path, icon: "trending_up", description: "Financial forecast and projections", keywords: "forecast projection future spending prediction", category: "Budget" }
    pages << { name: "Budget Insights", path: budget_reports_insights_path, icon: "lightbulb", description: "AI-driven budget insights and tips", keywords: "insights tips suggestions optimization", category: "Budget" }
    pages << { name: "Year over Year", path: budget_reports_year_over_year_path, icon: "calendar_view_month", description: "Year-over-year comparison", keywords: "year over year annual comparison yoy", category: "Budget" }
    pages << { name: "Monthly Digest", path: budget_reports_digest_path, icon: "newspaper", description: "Monthly financial digest", keywords: "digest monthly summary newsletter", category: "Budget" }
    pages << { name: "Cash Flow", path: budget_reports_cash_flow_path, icon: "water_drop", description: "Cash flow analysis", keywords: "cash flow in out money movement", category: "Budget" }
    pages << { name: "Subscription Audit", path: budget_reports_subscription_audit_path, icon: "subscriptions", description: "Audit recurring subscriptions", keywords: "subscription audit review recurring", category: "Budget" }
    pages << { name: "Bill Negotiation", path: budget_reports_bill_tracker_path, icon: "handshake", description: "Track bill negotiation savings", keywords: "bill negotiation tracker savings lower", category: "Budget" }
    pages << { name: "Annual Review", path: budget_reports_annual_review_path, icon: "auto_awesome", description: "Annual financial review", keywords: "annual review year end summary", category: "Budget" }
    pages << { name: "Spending Velocity", path: budget_reports_spending_velocity_path, icon: "speed", description: "Track how fast you are spending", keywords: "spending velocity burn rate pace", category: "Budget" }
    pages << { name: "Category Deep Dive", path: budget_reports_category_drill_path, icon: "zoom_in", description: "Deep dive into a spending category", keywords: "category detail drill down spending", category: "Budget" }
    pages << { name: "Income Tracker", path: budget_reports_income_tracker_path, icon: "attach_money", description: "Track income sources and trends", keywords: "income tracker salary earnings sources", category: "Budget" }
    pages << { name: "Spending Patterns", path: budget_reports_spending_patterns_path, icon: "pattern", description: "Identify spending patterns and habits", keywords: "spending patterns habits trends", category: "Budget" }
    pages << { name: "Spending Heatmap", path: budget_spending_heatmap_path, icon: "grid_on", description: "Heatmap of spending by day and category", keywords: "heatmap spending calendar visual", category: "Budget" }
    pages << { name: "Savings Projection", path: budget_savings_projection_path, icon: "moving", description: "Project future savings growth", keywords: "savings projection forecast growth compound", category: "Budget" }
    pages << { name: "Spending Anomalies", path: budget_spending_anomalies_path, icon: "error_outline", description: "Detect unusual spending patterns", keywords: "anomalies unusual spending outliers", category: "Budget" }
    pages << { name: "Income Allocator", path: budget_income_allocator_path, icon: "tune", description: "Allocate income to buckets", keywords: "income allocator 50/30/20 budget split", category: "Budget" }
    pages << { name: "Goal Planner", path: budget_goal_planner_path, icon: "map", description: "Plan and model financial goals", keywords: "goal planner timeline model savings", category: "Budget" }
    pages << { name: "Recurring Analyzer", path: budget_recurring_analyzer_path, icon: "autorenew", description: "Analyze recurring spending patterns", keywords: "recurring analyzer subscriptions bills audit", category: "Budget" }
    pages << { name: "Net Worth Details", path: budget_reports_net_worth_details_path, icon: "account_balance", description: "Detailed net worth breakdown", keywords: "net worth details assets liabilities breakdown", category: "Budget" }
    pages << { name: "Net Worth Forecast", path: budget_net_worth_forecast_path, icon: "timeline", description: "Forecast future net worth", keywords: "net worth forecast projection future", category: "Budget" }
    pages << { name: "Expense Forecast", path: budget_expense_forecast_path, icon: "cloud", description: "Forecast upcoming expenses", keywords: "expense forecast predict upcoming bills", category: "Budget" }
    pages << { name: "Bill Splitter", path: budget_bill_splitter_path, icon: "group", description: "Split bills with others", keywords: "bill splitter share divide roommate", category: "Budget" }
    pages << { name: "Subscriptions", path: budget_subscription_manager_path, icon: "subscriptions", description: "Manage all subscriptions", keywords: "subscriptions manager recurring services", category: "Budget" }
    pages << { name: "Savings Challenges", path: budget_savings_challenges_path, icon: "military_tech", description: "Fun savings challenges", keywords: "savings challenges gamification 52 week", category: "Budget" }
    pages << { name: "Cash Flow Planner", path: budget_cash_flow_planner_path, icon: "water_drop", description: "Plan cash flow weeks ahead", keywords: "cash flow planner upcoming schedule", category: "Budget" }
    pages << { name: "Spending Profile", path: budget_spending_personality_path, icon: "face", description: "Discover your spending personality", keywords: "spending personality profile type quiz", category: "Budget" }
    pages << { name: "Year in Review", path: budget_year_in_review_path, icon: "celebration", description: "Annual financial year in review", keywords: "year in review wrapped annual recap", category: "Budget" }
    pages << { name: "Lifestyle Inflation", path: budget_lifestyle_inflation_path, icon: "trending_up", description: "Track lifestyle inflation over time", keywords: "lifestyle inflation creep spending growth", category: "Budget" }

    # ── Tools ────────────────────────────────────────────────
    pages << { name: "Search", path: search_path, icon: "search", description: "Search trades, notes, journal, and transactions", keywords: "search find query lookup", category: "Tools" }
    pages << { name: "Quick Search", path: quick_search_path, icon: "manage_search", description: "Command palette and page navigation", keywords: "quick search command palette navigate go to", category: "Tools" }
    pages << { name: "Timeline", path: timeline_path, icon: "timeline", description: "Activity timeline across all areas", keywords: "timeline activity history events", category: "Tools" }
    pages << { name: "Daily Review", path: daily_review_path, icon: "today", description: "Daily review and reflection", keywords: "daily review today reflection recap", category: "Tools" }
    pages << { name: "Monthly Report", path: monthly_report_path, icon: "calendar_month", description: "Monthly performance report", keywords: "monthly report summary recap", category: "Tools" }
    pages << { name: "Weekly Digest", path: digest_path, icon: "summarize", description: "Weekly activity digest", keywords: "weekly digest summary newsletter", category: "Tools" }
    pages << { name: "Notifications", path: notifications_path, icon: "notifications", description: "View all notifications", keywords: "notifications alerts messages", category: "Tools" }
    pages << { name: "Settings", path: settings_path, icon: "settings", description: "Application settings and API configuration", keywords: "settings config preferences api tokens", category: "Tools" }
    pages << { name: "Getting Started", path: getting_started_path, icon: "rocket_launch", description: "Setup guide and onboarding", keywords: "getting started guide setup onboarding help", category: "Tools" }
    pages << { name: "Export Data", path: data_export_index_path, icon: "download", description: "Export trades, notes, and budget data", keywords: "export download csv json data backup", category: "Tools" }
    pages << { name: "Account Statement", path: data_export_account_statement_path, icon: "description", description: "Generate an account statement", keywords: "account statement official report", category: "Tools" }
    pages << { name: "Comparison Tool", path: comparison_path, icon: "compare", description: "Compare two trades side by side", keywords: "comparison trade side by side diff", category: "Tools" }
    pages << { name: "Performance Benchmarks", path: performance_benchmarks_path, icon: "leaderboard", description: "Compare your performance to industry benchmarks", keywords: "benchmarks ranking percentile tier level", category: "Tools" }
    pages << { name: "Trend Analyzer", path: trend_analyzer_path, icon: "insights", description: "Detect behavioral and performance trends over time", keywords: "trends analyzer patterns behavior rolling average", category: "Tools" }
    pages << { name: "Mood & Performance", path: mood_performance_path, icon: "psychology_alt", description: "Analyze how mood affects trading performance", keywords: "mood emotions performance psychology correlation", category: "Tools" }
    pages << { name: "Sizing Advisor", path: sizing_advisor_path, icon: "tune", description: "Kelly Criterion and position sizing recommendations", keywords: "sizing advisor kelly criterion position risk management", category: "Tools" }
    pages << { name: "Smart Alerts", path: smart_alerts_path, icon: "notifications_active", description: "Intelligent cross-product alerts and warnings", keywords: "smart alerts warnings risk notifications", category: "Tools" }
    pages << { name: "Goal Tracker", path: goal_tracker_path, icon: "flag", description: "Unified goal tracking across trading, budget, and writing", keywords: "goals tracker targets milestones progress", category: "Tools" }
    pages << { name: "Habit Tracker", path: habit_tracker_path, icon: "self_improvement", description: "Track daily trading and writing habits", keywords: "habits tracker daily discipline streak routine", category: "Tools" }
    pages << { name: "Portfolio Overview", path: portfolio_overview_path, icon: "account_balance", description: "Bird's-eye view of your complete financial picture", keywords: "portfolio overview net worth total assets finances", category: "Tools" }
    pages << { name: "Cross-Product Insights", path: cross_product_insights_path, icon: "hub", description: "How trading, journaling, notes, and spending correlate", keywords: "cross product insights correlations journal mood spending", category: "Tools" }
    pages << { name: "Weekly Planner", path: weekly_planner_path, icon: "date_range", description: "Week-at-a-glance planning view", keywords: "weekly planner schedule plan calendar week", category: "Tools" }
    pages << { name: "Account Health", path: account_health_path, icon: "health_and_safety", description: "Comprehensive account health score across trading, budget, and behavior", keywords: "account health score wellness trading financial behavioral", category: "Overview" }
    pages << { name: "Morning Briefing", path: morning_briefing_path, icon: "wb_sunny", description: "Start your day prepared with readiness score, focus items, and financial snapshot", keywords: "morning briefing daily start readiness score focus", category: "Overview" }
    pages << { name: "FIRE Calculator", path: budget_fire_calculator_path, icon: "local_fire_department", description: "Financial Independence Retire Early calculator", keywords: "fire calculator retirement independence savings", category: "Budget" }
    pages << { name: "Purchase Advisor", path: budget_purchase_advisor_path, icon: "shopping_cart", description: "Should you buy it? Affordability analysis", keywords: "purchase advisor buy decision affordability", category: "Budget" }
    pages << { name: "Net Worth Dashboard", path: budget_net_worth_dashboard_path, icon: "account_balance", description: "Assets vs liabilities dashboard", keywords: "net worth dashboard assets liabilities milestones", category: "Budget" }
    pages << { name: "Money Calendar", path: budget_money_calendar_path, icon: "event_note", description: "Calendar with daily spending amounts", keywords: "money calendar daily spending visual", category: "Budget" }
    pages << { name: "Impulse Tracker", path: budget_impulse_tracker_path, icon: "bolt", description: "Detect and track impulse spending", keywords: "impulse tracker spending patterns emotional", category: "Budget" }
    pages << { name: "Paycheck Planner", path: budget_paycheck_planner_path, icon: "payments", description: "Zero-based allocation per paycheck", keywords: "paycheck planner allocate income zero-based", category: "Budget" }
    pages << { name: "Forecast Accuracy", path: budget_forecast_accuracy_path, icon: "fact_check", description: "How accurate were your budget forecasts", keywords: "forecast accuracy budget vs actual comparison", category: "Budget" }
    pages << { name: "Spending Watchdog", path: budget_spending_watchdog_path, icon: "notifications_active", description: "Smart spending alerts and warnings", keywords: "spending watchdog alerts overspending warnings", category: "Budget" }
    pages << { name: "Performance Heatmap", path: performance_heatmap_path, icon: "grid_on", description: "Multi-dimensional win rate heatmaps", keywords: "heatmap performance win rate day hour symbol", category: "Reports" }
    pages << { name: "Loss Recovery", path: loss_recovery_path, icon: "healing", description: "Drawdown recovery planning and milestones", keywords: "loss recovery drawdown plan healing", category: "Trading" }
    pages << { name: "R:R Optimizer", path: rr_optimizer_path, icon: "tune", description: "Risk-reward distribution and Kelly Criterion", keywords: "risk reward optimizer kelly criterion ratio", category: "Trading" }
    pages << { name: "Session Analyzer", path: session_analyzer_path, icon: "view_timeline", description: "Daily session grading and tilt detection", keywords: "session analyzer daily grading tilt", category: "Trading" }
    pages << { name: "Breakeven Analyzer", path: breakeven_analyzer_path, icon: "balance", description: "Breakeven win rate and sensitivity analysis", keywords: "breakeven analyzer win rate sensitivity", category: "Trading" }
    pages << { name: "W/L Patterns", path: wl_patterns_path, icon: "casino", description: "Streak distribution and conditional probabilities", keywords: "win loss patterns streak probability conditional", category: "Trading" }
    pages << { name: "Entry Timing", path: entry_timing_path, icon: "timer", description: "MAE distribution and entry quality scores", keywords: "entry timing mae adverse excursion quality", category: "Trading" }
    pages << { name: "Writing Goals", path: writing_goals_path, icon: "flag", description: "Daily, weekly, and monthly word count goals", keywords: "writing goals word count target daily weekly", category: "Notes" }
    pages << { name: "Word Analysis", path: word_frequency_path, icon: "text_fields", description: "Word frequency, bigrams, and readability", keywords: "word frequency bigrams readability flesch", category: "Notes" }
    pages << { name: "Sentiment Analysis", path: note_sentiment_path, icon: "mood", description: "Keyword-based sentiment analysis of notes", keywords: "sentiment analysis mood positive negative notes", category: "Notes" }
    pages << { name: "Topics", path: note_topics_path, icon: "category", description: "Topic clustering and emerging trends", keywords: "topics clusters emerging fading trends notes", category: "Notes" }
    pages << { name: "Bookmarks", path: note_bookmarks_path, icon: "bookmarks", description: "Pinned and favorited notes curation", keywords: "bookmarks favorites pinned notes collection", category: "Notes" }
    pages << { name: "Export Center", path: note_export_center_path, icon: "cloud_download", description: "Export sizes, backup health for notes", keywords: "export center backup download notes", category: "Notes" }
    pages << { name: "Weekly Report", path: weekly_report_path, icon: "summarize", description: "Cross-product weekly summary report", keywords: "weekly report summary cross-product recap", category: "Tools" }
    pages << { name: "Drawdown Tracker", path: drawdown_tracker_path, icon: "trending_down", description: "Track drawdowns, recovery progress, and risk rules", keywords: "drawdown tracker recovery peak trough risk", category: "Trading" }
    pages << { name: "Performance Attribution", path: performance_attribution_path, icon: "pie_chart", description: "Break down P&L by symbol, time, side, and more", keywords: "attribution breakdown contribution detractor symbol side", category: "Reports" }
    pages << { name: "Journal Prompts", path: journal_prompts_path, icon: "psychology", description: "Context-aware journaling prompts based on today's trading", keywords: "journal prompts writing reflection psychology questions", category: "Trading" }
    pages << { name: "Risk Rules", path: risk_rules_path, icon: "gavel", description: "Define and enforce personal trading risk rules", keywords: "risk rules engine limits daily max loss position size", category: "Trading" }
    pages << { name: "Market Session", path: market_session_path, icon: "schedule", description: "Live market session clock and trading hours", keywords: "market session timer clock hours open close", category: "Trading" }
    pages << { name: "Trade Calendar", path: trade_calendar_path, icon: "calendar_month", description: "Monthly calendar with individual trades per day", keywords: "trade calendar monthly day individual results visual", category: "Trading" }
    pages << { name: "Correlation Matrix", path: correlation_matrix_path, icon: "grid_view", description: "Symbol-to-symbol correlation heatmap and diversification score", keywords: "correlation matrix heatmap symbols diversification hedging", category: "Reports" }
    pages << { name: "Win/Loss Analysis", path: win_loss_analysis_path, icon: "compare_arrows", description: "Deep dive into what separates winners from losers", keywords: "win loss analysis comparison profile edge payoff ratio", category: "Reports" }
    pages << { name: "Spending vs Trading", path: spending_trading_path, icon: "sync_alt", description: "Correlation between spending habits and trading performance", keywords: "spending trading correlation budget performance habits", category: "Tools" }
    pages << { name: "Trade Templates", path: trade_templates_path, icon: "content_copy", description: "Save and reuse common trade setups", keywords: "trade templates setup preset reuse quick copy", category: "Trading" }
    pages << { name: "Snapshot Report", path: snapshot_report_path, icon: "summarize", description: "Printable performance snapshot with grade for any period", keywords: "snapshot report summary print grade period performance", category: "Reports" }
    pages << { name: "Streak Calendar", path: streak_calendar_path, icon: "local_fire_department", description: "GitHub-style activity heatmap for trading and journaling", keywords: "streak calendar heatmap activity consistency fire gamification", category: "Tools" }
    pages << { name: "Equity Simulator", path: equity_simulator_path, icon: "science", description: "What-if simulator: change position sizes, remove worst trades, add stop-losses", keywords: "equity simulator what if position size stop loss backtest", category: "Trading" }
    pages << { name: "Playbook Comparison", path: playbook_comparison_path, icon: "difference", description: "Side-by-side comparison of playbook performance", keywords: "playbook comparison strategy performance side by side", category: "Reports" }
    pages << { name: "Sizing Backtest", path: sizing_backtest_path, icon: "science", description: "Backtest position sizing strategies on your actual trades", keywords: "sizing backtest kelly criterion fixed fractional anti-martingale position", category: "Trading" }
    pages << { name: "Consistency Report", path: consistency_report_path, icon: "verified", description: "Behavioral consistency score across 9 dimensions with radar chart", keywords: "consistency report discipline behavioral score radar", category: "Reports" }
    pages << { name: "Symbol Deep Dive", path: symbol_deep_dive_path, icon: "query_stats", description: "Exhaustive performance breakdown for a single symbol", keywords: "symbol deep dive breakdown analysis ticker performance detail", category: "Trading" }

    pages
  end
end

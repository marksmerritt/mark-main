class AccountHealthController < ApplicationController
  include ActionView::Helpers::NumberHelper

  def show
    threads = {}

    # === Trading API ===
    if api_token.present?
      threads[:trades] = Thread.new do
        result = api_client.trades(per_page: 2000, status: "closed")
        result.is_a?(Hash) ? (result["trades"] || []) : Array(result)
      rescue => e
        Rails.logger.error("account_health trades: #{e.message}")
        []
      end

      threads[:overview] = Thread.new do
        api_client.overview
      rescue => e
        Rails.logger.error("account_health overview: #{e.message}")
        {}
      end

      threads[:streaks] = Thread.new do
        api_client.streaks
      rescue => e
        Rails.logger.error("account_health streaks: #{e.message}")
        {}
      end

      threads[:journal] = Thread.new do
        result = api_client.journal_entries(per_page: 500)
        result.is_a?(Hash) ? (result["journal_entries"] || []) : Array(result)
      rescue => e
        Rails.logger.error("account_health journal: #{e.message}")
        []
      end

      threads[:review_stats] = Thread.new do
        api_client.review_stats
      rescue => e
        Rails.logger.error("account_health review_stats: #{e.message}")
        {}
      end

      threads[:equity] = Thread.new do
        api_client.equity_curve
      rescue => e
        Rails.logger.error("account_health equity: #{e.message}")
        {}
      end
    end

    # === Budget API ===
    if budget_api_token.present?
      threads[:budget_overview] = Thread.new do
        budget_client.budget_overview
      rescue => e
        Rails.logger.error("account_health budget_overview: #{e.message}")
        {}
      end

      threads[:current_budget] = Thread.new do
        budget_client.current_budget
      rescue => e
        Rails.logger.error("account_health current_budget: #{e.message}")
        {}
      end

      threads[:debt] = Thread.new do
        budget_client.debt_overview
      rescue => e
        Rails.logger.error("account_health debt: #{e.message}")
        {}
      end

      threads[:transactions] = Thread.new do
        result = budget_client.transactions(per_page: 500)
        result.is_a?(Hash) ? (result["transactions"] || result) : Array(result)
      rescue => e
        Rails.logger.error("account_health transactions: #{e.message}")
        []
      end
    end

    # === Notes API ===
    if notes_api_token.present?
      threads[:notes_stats] = Thread.new do
        notes_client.stats
      rescue => e
        Rails.logger.error("account_health notes_stats: #{e.message}")
        {}
      end

      threads[:notes] = Thread.new do
        result = notes_client.notes(per_page: 200)
        result.is_a?(Hash) ? (result["notes"] || []) : Array(result)
      rescue => e
        Rails.logger.error("account_health notes: #{e.message}")
        []
      end
    end

    # === Collect Results ===
    trades = (threads[:trades]&.value || []).select { |t| t.is_a?(Hash) }
    overview = threads[:overview]&.value || {}
    overview = {} unless overview.is_a?(Hash)
    streaks = threads[:streaks]&.value || {}
    streaks = {} unless streaks.is_a?(Hash)
    journal_entries = (threads[:journal]&.value || []).select { |e| e.is_a?(Hash) }
    review_stats = threads[:review_stats]&.value || {}
    review_stats = {} unless review_stats.is_a?(Hash)
    equity_result = threads[:equity]&.value || {}
    equity_curve = equity_result.is_a?(Hash) ? (equity_result["equity_curve"] || []) : []

    budget_overview = threads[:budget_overview]&.value || {}
    budget_overview = {} unless budget_overview.is_a?(Hash)
    current_budget = threads[:current_budget]&.value || {}
    current_budget = {} unless current_budget.is_a?(Hash)
    debt_data = threads[:debt]&.value || {}
    debt_data = {} unless debt_data.is_a?(Hash)
    transactions = threads[:transactions]&.value || []
    transactions = transactions.is_a?(Array) ? transactions.select { |t| t.is_a?(Hash) } : []

    notes_stats = threads[:notes_stats]&.value || {}
    notes_stats = {} unless notes_stats.is_a?(Hash)
    notes = (threads[:notes]&.value || []).select { |n| n.is_a?(Hash) }

    # === Compute Sub-Scores ===
    @trading_scores = compute_trading_health(trades, overview, streaks, equity_curve)
    @financial_scores = compute_financial_health(budget_overview, current_budget, debt_data, transactions)
    @behavioral_scores = compute_behavioral_health(trades, journal_entries, review_stats, notes_stats, notes)

    # === Overall Score ===
    trading_total = @trading_scores.sum { |s| s[:score] }
    financial_total = @financial_scores.sum { |s| s[:score] }
    behavioral_total = @behavioral_scores.sum { |s| s[:score] }
    @overall_score = trading_total + financial_total + behavioral_total

    @tier = score_tier(@overall_score)

    # === Top 3 Improvements ===
    all_scores = @trading_scores.map { |s| s.merge(category: "Trading") } +
                 @financial_scores.map { |s| s.merge(category: "Financial") } +
                 @behavioral_scores.map { |s| s.merge(category: "Behavioral") }
    @improvements = all_scores.sort_by { |s| s[:score].to_f / s[:max].to_f }.first(3)

    # === 30-Day Trend ===
    @trend = compute_trend(trades, journal_entries, transactions, notes)
  end

  private

  # ── Trading Health (40 points max) ─────────────────────────

  def compute_trading_health(trades, overview, streaks, equity_curve)
    scores = []

    # Win Rate (0-10)
    win_rate = overview["win_rate"].to_f
    if trades.any?
      wins = trades.count { |t| t["pnl"].to_f > 0 }
      win_rate = (wins.to_f / trades.count * 100).round(1)
    end
    wr_score = if win_rate > 60 then 10
               elsif win_rate > 50 then 7
               elsif win_rate > 40 then 4
               else 2
               end
    wr_score = 0 if trades.empty? && overview["total_trades"].to_i == 0
    scores << {
      name: "Win Rate", icon: "gps_fixed", score: wr_score, max: 10,
      value: "#{win_rate.round(1)}%",
      diagnosis: wr_score >= 7 ? "Solid win rate" : "Win rate needs improvement",
      recommendation: wr_score >= 7 ? "Maintain selectivity in trade entries." : "Be more selective with entries and tighten criteria."
    }

    # Profit Factor (0-10)
    wins_arr = trades.select { |t| t["pnl"].to_f > 0 }
    losses_arr = trades.select { |t| t["pnl"].to_f < 0 }
    gross_profit = wins_arr.sum { |t| t["pnl"].to_f }
    gross_loss = losses_arr.sum { |t| t["pnl"].to_f.abs }
    profit_factor = gross_loss > 0 ? (gross_profit / gross_loss).round(2) : (gross_profit > 0 ? 99.0 : 0.0)
    pf_score = if profit_factor > 2.0 then 10
               elsif profit_factor > 1.5 then 8
               elsif profit_factor > 1.0 then 5
               else 2
               end
    pf_score = 0 if trades.empty?
    scores << {
      name: "Profit Factor", icon: "paid", score: pf_score, max: 10,
      value: profit_factor > 90 ? "N/A" : profit_factor.to_s,
      diagnosis: pf_score >= 8 ? "Strong edge" : pf_score >= 5 ? "Marginal edge" : "Losing edge",
      recommendation: pf_score >= 8 ? "Keep managing risk well." : "Cut losses faster and let winners run."
    }

    # Consistency (0-10)
    monthly_pnl = {}
    trades.each do |t|
      month = (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 7)
      next unless month
      monthly_pnl[month] ||= 0
      monthly_pnl[month] += t["pnl"].to_f
    end
    profitable_months = monthly_pnl.values.count { |v| v > 0 }
    total_months = [monthly_pnl.count, 1].max
    month_pct = (profitable_months.to_f / total_months * 100).round(1)
    cons_score = if month_pct >= 80 then 10
                 elsif month_pct >= 60 then 7
                 elsif month_pct >= 40 then 4
                 else 2
                 end
    cons_score = 0 if trades.empty?
    scores << {
      name: "Consistency", icon: "straighten", score: cons_score, max: 10,
      value: "#{profitable_months}/#{monthly_pnl.count} months profitable",
      diagnosis: cons_score >= 7 ? "Reliably profitable" : "Inconsistent returns",
      recommendation: cons_score >= 7 ? "Continue steady position sizing." : "Reduce size during losing streaks for steadier months."
    }

    # Risk Management (0-10)
    peak = 0
    max_dd = 0
    running = 0
    trades.sort_by { |t| t["exit_time"] || t["entry_time"] || "" }.each do |t|
      running += t["pnl"].to_f
      peak = running if running > peak
      dd = peak - running
      max_dd = dd if dd > max_dd
    end
    dd_pct = peak > 0 ? (max_dd / peak * 100).round(1) : 0
    risk_score = if dd_pct <= 10 then 10
                 elsif dd_pct <= 20 then 8
                 elsif dd_pct <= 30 then 5
                 elsif dd_pct <= 50 then 3
                 else 1
                 end
    risk_score = 0 if trades.empty?
    scores << {
      name: "Risk Management", icon: "shield", score: risk_score, max: 10,
      value: "#{dd_pct}% max drawdown",
      diagnosis: risk_score >= 8 ? "Capital well-preserved" : "Drawdowns are too deep",
      recommendation: risk_score >= 8 ? "Strong capital preservation." : "Use stops and reduce size after consecutive losses."
    }

    scores
  end

  # ── Financial Health (30 points max) ───────────────────────

  def compute_financial_health(budget_overview, current_budget, debt_data, transactions)
    scores = []

    # Budget Adherence (0-10)
    categories = current_budget["budget_categories"] || current_budget["categories"] || []
    categories = categories.is_a?(Array) ? categories.select { |c| c.is_a?(Hash) } : []
    if categories.any?
      under_limit = categories.count do |cat|
        budgeted = cat["budgeted"].to_f
        spent = cat["spent"].to_f
        budgeted > 0 ? spent <= budgeted : true
      end
      adherence_pct = (under_limit.to_f / categories.count * 100).round(1)
    else
      total_budgeted = budget_overview["total_budgeted"].to_f
      total_spent = budget_overview["total_spent"].to_f
      adherence_pct = total_budgeted > 0 ? [((total_budgeted - total_spent) / total_budgeted * 100 + 50), 100].min.round(1) : 0
      adherence_pct = [adherence_pct, 0].max
    end
    ba_score = if adherence_pct >= 90 then 10
               elsif adherence_pct >= 70 then 7
               elsif adherence_pct >= 50 then 4
               else 2
               end
    ba_score = 0 unless budget_api_token.present?
    scores << {
      name: "Budget Adherence", icon: "account_balance_wallet", score: ba_score, max: 10,
      value: "#{adherence_pct.round(0)}% categories on track",
      diagnosis: ba_score >= 7 ? "Budget well-managed" : "Overspending in multiple areas",
      recommendation: ba_score >= 7 ? "Keep tracking every transaction." : "Review overspent categories and set stricter limits.",
      link_path: "budget_dashboard_path", link_text: "Budget"
    }

    # Savings Rate (0-10)
    income = budget_overview["income"].to_f.nonzero? || budget_overview["total_income"].to_f
    total_spent = budget_overview["total_spent"].to_f
    if income > 0
      savings_rate = ((income - total_spent) / income * 100).round(1)
    else
      savings_rate = 0
    end
    sr_score = if savings_rate >= 30 then 10
               elsif savings_rate >= 20 then 8
               elsif savings_rate >= 10 then 5
               elsif savings_rate > 0 then 3
               else 1
               end
    sr_score = 0 unless budget_api_token.present?
    scores << {
      name: "Savings Rate", icon: "savings", score: sr_score, max: 10,
      value: "#{savings_rate.round(1)}%",
      diagnosis: sr_score >= 8 ? "Excellent savings discipline" : sr_score >= 5 ? "Moderate savings" : "Very low savings",
      recommendation: sr_score >= 8 ? "Great savings rate. Consider investing surplus." : "Target at least 20% savings rate.",
      link_path: "budget_savings_path", link_text: "Savings"
    }

    # Debt Load (0-10)
    debts = debt_data["debts"] || debt_data["debt_accounts"] || []
    debts = debts.is_a?(Array) ? debts.select { |d| d.is_a?(Hash) } : []
    total_debt = debts.sum { |d| d["current_balance"].to_f }
    if income > 0 && debts.any?
      dti = (total_debt / (income * 12) * 100).round(1) # annual income estimate
      dl_score = if dti <= 20 then 10
                 elsif dti <= 40 then 7
                 elsif dti <= 60 then 4
                 else 2
                 end
    elsif debts.empty?
      dl_score = 10
      dti = 0
    else
      dl_score = 5
      dti = 0
    end
    dl_score = 0 unless budget_api_token.present?
    scores << {
      name: "Debt Load", icon: "credit_card", score: dl_score, max: 10,
      value: debts.any? ? "#{number_to_currency(total_debt)} (#{dti}% DTI)" : "No debt",
      diagnosis: dl_score >= 7 ? "Debt under control" : "High debt burden",
      recommendation: dl_score >= 7 ? "Maintain low debt levels." : "Prioritize debt payoff with snowball or avalanche method.",
      link_path: "budget_debt_accounts_path", link_text: "Debt"
    }

    scores
  end

  # ── Behavioral Health (30 points max) ──────────────────────

  def compute_behavioral_health(trades, journal_entries, review_stats, notes_stats, notes)
    scores = []

    # Journal Consistency (0-10)
    trading_dates = trades.filter_map do |t|
      date_str = (t["entry_time"] || t["exit_time"])&.to_s&.slice(0, 10)
      Date.parse(date_str) rescue nil
    end.uniq

    journal_dates = journal_entries.filter_map do |e|
      date_str = (e["date"] || e["created_at"])&.to_s&.slice(0, 10)
      Date.parse(date_str) rescue nil
    end.uniq

    if trading_dates.any?
      journaled_trading_days = (trading_dates & journal_dates).count
      journal_pct = (journaled_trading_days.to_f / trading_dates.count * 100).round(1)
    else
      journal_pct = journal_entries.any? ? 50.0 : 0.0
    end
    jc_score = if journal_pct >= 80 then 10
               elsif journal_pct >= 60 then 7
               elsif journal_pct >= 40 then 4
               else 2
               end
    jc_score = 0 unless api_token.present?
    scores << {
      name: "Journal Consistency", icon: "auto_stories", score: jc_score, max: 10,
      value: "#{journal_pct.round(0)}% of trading days journaled",
      diagnosis: jc_score >= 7 ? "Strong journaling habit" : "Inconsistent journaling",
      recommendation: jc_score >= 7 ? "Keep journaling every trading day." : "Write a quick journal entry after each trading session.",
      link_path: "journal_entries_path", link_text: "Journal"
    }

    # Review Discipline (0-10)
    reviewed = review_stats["reviewed_count"].to_i
    total_reviewable = review_stats["total_count"].to_i
    if total_reviewable > 0
      review_pct = (reviewed.to_f / total_reviewable * 100).round(1)
    else
      # Estimate from trades with review_rating
      reviewed_trades = trades.count { |t| t["review_rating"].present? || t["review_notes"].present? }
      review_pct = trades.any? ? (reviewed_trades.to_f / trades.count * 100).round(1) : 0.0
    end
    rd_score = if review_pct >= 80 then 10
               elsif review_pct >= 60 then 7
               elsif review_pct >= 40 then 4
               else 2
               end
    rd_score = 0 unless api_token.present?
    scores << {
      name: "Review Discipline", icon: "rate_review", score: rd_score, max: 10,
      value: "#{review_pct.round(0)}% of trades reviewed",
      diagnosis: rd_score >= 7 ? "Thorough review process" : "Many trades go unreviewed",
      recommendation: rd_score >= 7 ? "Reviews are building your edge." : "Review every closed trade to identify patterns.",
      link_path: "review_trades_path", link_text: "Reviews"
    }

    # Note-Taking Activity (0-10)
    total_notes = notes_stats["total_notes"].to_i
    recent_notes = notes_stats["this_week"].to_i.nonzero? || notes_stats["recent_count"].to_i

    # Also look at recent activity from notes data
    last_30 = Date.today - 30
    recent_from_data = notes.count do |n|
      date_str = (n["updated_at"] || n["created_at"])&.to_s&.slice(0, 10)
      d = Date.parse(date_str) rescue nil
      d && d >= last_30
    end
    recent_notes = [recent_notes, recent_from_data].max

    nt_score = if recent_notes >= 10 then 10
               elsif recent_notes >= 5 then 7
               elsif recent_notes >= 2 then 4
               elsif total_notes > 0 then 2
               else 1
               end
    nt_score = 0 unless notes_api_token.present?
    scores << {
      name: "Note-Taking", icon: "edit_note", score: nt_score, max: 10,
      value: "#{recent_notes} notes in last 30 days",
      diagnosis: nt_score >= 7 ? "Active knowledge building" : "Notes activity is low",
      recommendation: nt_score >= 7 ? "Great note-taking habit." : "Capture trading lessons and ideas as notes regularly.",
      link_path: "notes_path", link_text: "Notes"
    }

    scores
  end

  # ── Score Tier ─────────────────────────────────────────────

  def score_tier(score)
    if score >= 80
      { label: "Excellent", color: "var(--positive)", message: "Your account is thriving", icon: "verified" }
    elsif score >= 60
      { label: "Good", color: "var(--primary)", message: "Solid foundation, room to grow", icon: "thumb_up" }
    elsif score >= 40
      { label: "Fair", color: "#f9a825", message: "Several areas need attention", icon: "info" }
    else
      { label: "Critical", color: "var(--negative)", message: "Immediate action recommended", icon: "warning" }
    end
  end

  # ── 30-Day Trend ───────────────────────────────────────────

  def compute_trend(trades, journal_entries, transactions, notes)
    weeks = []
    4.times do |i|
      week_end = Date.today - (i * 7)
      week_start = week_end - 6

      # Trading score for the week
      week_trades = trades.select do |t|
        d = (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 10)
        date = Date.parse(d) rescue nil
        date && date >= week_start && date <= week_end
      end
      week_wins = week_trades.count { |t| t["pnl"].to_f > 0 }
      week_wr = week_trades.any? ? (week_wins.to_f / week_trades.count * 100) : 0

      # Journal for the week
      week_journal = journal_entries.count do |e|
        d = (e["date"] || e["created_at"])&.to_s&.slice(0, 10)
        date = Date.parse(d) rescue nil
        date && date >= week_start && date <= week_end
      end

      # Notes for the week
      week_notes = notes.count do |n|
        d = (n["updated_at"] || n["created_at"])&.to_s&.slice(0, 10)
        date = Date.parse(d) rescue nil
        date && date >= week_start && date <= week_end
      end

      # Simplified weekly score (proportional to 100)
      t_score = week_wr >= 50 ? 40 : (week_wr > 0 ? 20 : 0)
      b_score = week_journal >= 3 ? 30 : (week_journal >= 1 ? 15 : 0)
      n_score = week_notes >= 3 ? 30 : (week_notes >= 1 ? 15 : 0)
      weekly_total = t_score + b_score + n_score

      weeks << {
        label: "#{week_start.strftime('%b %d')} - #{week_end.strftime('%b %d')}",
        score: weekly_total,
        trades: week_trades.count,
        journal: week_journal,
        notes: week_notes
      }
    end

    weeks.reverse
  end
end

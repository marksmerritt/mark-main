class WeeklyReportController < ApplicationController
  include ActionView::Helpers::NumberHelper

  def show
    @week_offset = params[:week].to_i
    @week_start = if params[:week_start].present?
      Date.parse(params[:week_start]) rescue Date.current.beginning_of_week(:monday)
    else
      Date.current.beginning_of_week(:monday) - @week_offset.weeks
    end
    @week_end = [@week_start + 6.days, Date.current].min
    @prev_week_start = @week_start - 1.week
    @prev_week_end = @prev_week_start + 6.days
    @is_current_week = @week_start == Date.current.beginning_of_week(:monday)

    threads = {}

    # ---- Trading API ----
    if api_token.present?
      threads[:trades] = Thread.new {
        result = api_client.trades(
          start_date: @week_start.to_s,
          end_date: (@week_end + 1.day).to_s,
          per_page: 200,
          status: "closed"
        ) rescue {}
        result.is_a?(Hash) ? (result["trades"] || []) : Array(result)
      }
      threads[:journal] = Thread.new {
        result = api_client.journal_entries(
          start_date: @week_start.to_s,
          end_date: @week_end.to_s,
          per_page: 50
        ) rescue {}
        result.is_a?(Hash) ? (result["journal_entries"] || []) : Array(result)
      }
      threads[:prev_trades] = Thread.new {
        result = api_client.trades(
          start_date: @prev_week_start.to_s,
          end_date: (@prev_week_end + 1.day).to_s,
          per_page: 200,
          status: "closed"
        ) rescue {}
        result.is_a?(Hash) ? (result["trades"] || []) : Array(result)
      }
    end

    # ---- Budget API ----
    if budget_api_token.present?
      threads[:transactions] = Thread.new {
        result = budget_client.transactions(
          start_date: @week_start.to_s,
          end_date: @week_end.to_s,
          per_page: 200
        ) rescue {}
        result.is_a?(Hash) ? (result["transactions"] || []) : Array(result)
      }
      threads[:prev_transactions] = Thread.new {
        result = budget_client.transactions(
          start_date: @prev_week_start.to_s,
          end_date: @prev_week_end.to_s,
          per_page: 200
        ) rescue {}
        result.is_a?(Hash) ? (result["transactions"] || []) : Array(result)
      }
      threads[:budget_overview] = Thread.new {
        budget_client.budget_overview(
          month: @week_start.month,
          year: @week_start.year
        ) rescue {}
      }
    end

    # ---- Notes API ----
    if notes_api_token.present?
      threads[:notes] = Thread.new {
        result = notes_client.notes(per_page: 200, sort: "updated_at_desc") rescue {}
        all = result.is_a?(Hash) ? (result["notes"] || []) : Array(result)
        all.select { |n|
          updated = n["updated_at"] || n["created_at"]
          next false unless updated
          date = Date.parse(updated.to_s) rescue nil
          date && date >= @week_start && date <= @week_end
        }
      }
      threads[:prev_notes] = Thread.new {
        result = notes_client.notes(per_page: 200, sort: "updated_at_desc") rescue {}
        all = result.is_a?(Hash) ? (result["notes"] || []) : Array(result)
        all.select { |n|
          updated = n["updated_at"] || n["created_at"]
          next false unless updated
          date = Date.parse(updated.to_s) rescue nil
          date && date >= @prev_week_start && date <= @prev_week_end
        }
      }
    end

    # Collect results
    @trades = threads[:trades]&.value || []
    @journal_entries = threads[:journal]&.value || []
    @prev_trades = threads[:prev_trades]&.value || []
    @transactions = threads[:transactions]&.value || []
    @prev_transactions = threads[:prev_transactions]&.value || []
    @budget_overview = threads[:budget_overview]&.value || {}
    @notes = threads[:notes]&.value || []
    @prev_notes = threads[:prev_notes]&.value || []

    compute_trading_summary
    compute_budget_summary
    compute_notes_summary
    compute_highlights
    compute_concerns
    compute_week_score
    compute_comparison
    compute_daily_breakdown
  end

  private

  # ---- Trading Summary ----
  def compute_trading_summary
    @trade_count = @trades.count
    @trade_wins = @trades.count { |t| t["pnl"].to_f > 0 }
    @trade_losses = @trades.count { |t| t["pnl"].to_f < 0 }
    @trade_breakeven = @trade_count - @trade_wins - @trade_losses
    @trade_win_rate = @trade_count > 0 ? (@trade_wins.to_f / @trade_count * 100).round(1) : 0
    @trade_pnl = @trades.sum { |t| t["pnl"].to_f }
    @trade_fees = @trades.sum { |t| t["fees"].to_f }
    @best_trade = @trades.max_by { |t| t["pnl"].to_f }
    @worst_trade = @trades.min_by { |t| t["pnl"].to_f }
    @avg_win = @trade_wins > 0 ? @trades.select { |t| t["pnl"].to_f > 0 }.sum { |t| t["pnl"].to_f } / @trade_wins : 0
    @avg_loss = @trade_losses > 0 ? @trades.select { |t| t["pnl"].to_f < 0 }.sum { |t| t["pnl"].to_f } / @trade_losses : 0

    # Streak
    sorted = @trades.sort_by { |t| t["exit_time"] || t["entry_time"] || "" }
    @streak = 0
    @streak_type = nil
    sorted.reverse_each do |t|
      pnl = t["pnl"].to_f
      next if pnl == 0
      current_type = pnl > 0 ? "win" : "loss"
      if @streak_type.nil?
        @streak_type = current_type
        @streak = 1
      elsif current_type == @streak_type
        @streak += 1
      else
        break
      end
    end

    # Trading days
    trade_dates = @trades.map { |t| (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 10) }.compact.uniq
    @trading_days = trade_dates.count
    @green_days = 0
    @red_days = 0
    trade_dates.each do |date|
      day_pnl = @trades.select { |t| (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 10) == date }.sum { |t| t["pnl"].to_f }
      day_pnl >= 0 ? @green_days += 1 : @red_days += 1
    end

    # Top symbols
    by_sym = {}
    @trades.each do |t|
      sym = t["symbol"] || "?"
      by_sym[sym] ||= { pnl: 0, count: 0 }
      by_sym[sym][:pnl] += t["pnl"].to_f
      by_sym[sym][:count] += 1
    end
    @top_symbols = by_sym.sort_by { |_, d| -d[:pnl] }.first(5)
  end

  # ---- Budget Summary ----
  def compute_budget_summary
    @budget_income = @transactions.select { |t| t["transaction_type"] == "income" }.sum { |t| t["amount"].to_f }
    @budget_spending = @transactions.select { |t| t["transaction_type"] != "income" }.sum { |t| t["amount"].to_f }
    @budget_savings = @budget_income - @budget_spending
    @transaction_count = @transactions.count

    by_cat = {}
    @transactions.select { |t| t["transaction_type"] != "income" }.each do |t|
      cat = t["category"] || t["budget_category"] || "Uncategorized"
      by_cat[cat] ||= 0
      by_cat[cat] += t["amount"].to_f
    end
    @top_categories = by_cat.sort_by { |_, v| -v }.first(5)

    @budgeted = @budget_overview.is_a?(Hash) ? @budget_overview["total_budgeted"].to_f : 0
    @budget_utilization = @budgeted > 0 ? (@budget_spending / @budgeted * 100).round(1) : 0
  end

  # ---- Notes Summary ----
  def compute_notes_summary
    @notes_count = @notes.count
    @notes_words = @notes.sum { |n| (n["word_count"] || n["content"]&.to_s&.split&.count || 0).to_i }
    @notes_notebooks = @notes.map { |n| n.dig("notebook", "name") }.compact.uniq
    @notes_notebooks_count = @notes_notebooks.count

    # Longest note
    @longest_note = @notes.max_by { |n| (n["word_count"] || n["content"]&.to_s&.split&.count || 0).to_i }
    @longest_note_words = @longest_note ? ((@longest_note["word_count"] || @longest_note["content"]&.to_s&.split&.count || 0).to_i) : 0

    # Writing days
    note_dates = @notes.map { |n| (n["updated_at"] || n["created_at"])&.to_s&.slice(0, 10) }.compact.uniq
    @writing_days = note_dates.count
    days_in_week = (@week_end - @week_start).to_i + 1
    @missed_writing_days = days_in_week - @writing_days
  end

  # ---- Highlights ----
  def compute_highlights
    @highlights = []

    # Trading highlights
    if @best_trade && @best_trade["pnl"].to_f > 0
      @highlights << {
        icon: "emoji_events",
        color: "var(--positive)",
        label: "Biggest Win",
        text: "#{@best_trade['symbol']} #{number_to_currency(@best_trade['pnl'])}"
      }
    end

    if @trade_win_rate >= 60 && @trade_count >= 3
      @highlights << {
        icon: "stars",
        color: "var(--positive)",
        label: "Strong Win Rate",
        text: "#{@trade_win_rate}% across #{@trade_count} trades"
      }
    end

    if @streak >= 3 && @streak_type == "win"
      @highlights << {
        icon: "local_fire_department",
        color: "#ff6d00",
        label: "Hot Streak",
        text: "#{@streak}-trade winning streak"
      }
    end

    # Budget highlights
    if @budget_savings > 0
      @highlights << {
        icon: "savings",
        color: "var(--positive)",
        label: "Biggest Save",
        text: "#{number_to_currency(@budget_savings)} net savings this week"
      }
    end

    if @budget_utilization > 0 && @budget_utilization <= 80
      @highlights << {
        icon: "check_circle",
        color: "var(--positive)",
        label: "Budget Discipline",
        text: "Only #{@budget_utilization}% of monthly budget used"
      }
    end

    # Notes highlights
    if @longest_note && @longest_note_words >= 200
      title = @longest_note["title"].presence || "Untitled"
      @highlights << {
        icon: "description",
        color: "#3f51b5",
        label: "Most Words",
        text: "#{number_with_delimiter(@longest_note_words)} words in \"#{truncate(title, length: 30)}\""
      }
    end

    if @writing_days >= 5
      @highlights << {
        icon: "edit_note",
        color: "#9c27b0",
        label: "Writing Consistency",
        text: "Wrote on #{@writing_days} out of #{(@week_end - @week_start).to_i + 1} days"
      }
    end
  end

  # ---- Concerns ----
  def compute_concerns
    @concerns = []

    # Trading concerns
    if @trade_pnl < 0 && @trade_count > 0
      @concerns << {
        icon: "trending_down",
        color: "var(--negative)",
        label: "Trading Losses",
        text: "#{number_to_currency(@trade_pnl)} net loss from #{@trade_count} trades"
      }
    end

    if @streak >= 3 && @streak_type == "loss"
      @concerns << {
        icon: "warning",
        color: "var(--negative)",
        label: "Losing Streak",
        text: "#{@streak}-trade losing streak — consider pausing"
      }
    end

    if @trade_win_rate < 40 && @trade_count >= 3
      @concerns << {
        icon: "trending_down",
        color: "var(--negative)",
        label: "Low Win Rate",
        text: "#{@trade_win_rate}% win rate needs attention"
      }
    end

    # Budget concerns
    if @budget_spending > @budget_income && @budget_income > 0
      @concerns << {
        icon: "money_off",
        color: "var(--negative)",
        label: "Overspending",
        text: "Spent #{number_to_currency(@budget_spending - @budget_income)} more than earned"
      }
    end

    if @budget_utilization > 100
      @concerns << {
        icon: "error",
        color: "var(--negative)",
        label: "Over Budget",
        text: "#{@budget_utilization}% of monthly budget already used"
      }
    end

    # Notes concerns
    if @missed_writing_days >= 4 && notes_api_token.present?
      @concerns << {
        icon: "edit_off",
        color: "#f9ab00",
        label: "Missed Writing Days",
        text: "Only wrote on #{@writing_days} of #{(@week_end - @week_start).to_i + 1} days"
      }
    end

    if @notes_count == 0 && notes_api_token.present?
      @concerns << {
        icon: "note",
        color: "#f9ab00",
        label: "No Notes",
        text: "No notes written this week"
      }
    end
  end

  # ---- Week Score ----
  def compute_week_score
    scores = []
    weights = []

    # Trading score (weight: 40)
    if api_token.present? && @trade_count > 0
      trading_score = 0
      trading_score += 30 if @trade_pnl > 0
      trading_score += 25 if @trade_win_rate >= 50
      trading_score += 20 if @green_days > @red_days
      trading_score += 15 if @streak_type == "win"
      trading_score += 10 if @journal_entries.count >= @trading_days
      scores << trading_score
      weights << 40
    end

    # Budget score (weight: 35)
    if budget_api_token.present? && @transaction_count > 0
      budget_score = 0
      budget_score += 35 if @budget_savings >= 0
      budget_score += 25 if @budget_utilization <= 85
      budget_score += 20 if @budget_utilization <= 100
      budget_score += 20 if @top_categories.count <= 8
      scores << budget_score
      weights << 35
    end

    # Notes score (weight: 25)
    if notes_api_token.present?
      days_in_week = (@week_end - @week_start).to_i + 1
      notes_score = 0
      notes_score += 30 if @notes_count >= 3
      notes_score += 25 if @notes_words >= 500
      notes_score += 25 if @writing_days >= (days_in_week * 0.5).ceil
      notes_score += 20 if @notes_notebooks_count >= 2
      scores << notes_score
      weights << 25
    end

    total_weight = weights.sum
    if total_weight > 0
      @week_score = scores.each_with_index.sum { |s, i| s * weights[i] }.to_f / total_weight
      @week_score = @week_score.round(0).to_i
    else
      @week_score = 0
    end

    @week_grade = case @week_score
                  when 90..100 then "A+"
                  when 80..89 then "A"
                  when 70..79 then "B+"
                  when 60..69 then "B"
                  when 50..59 then "C+"
                  when 40..49 then "C"
                  when 30..39 then "D"
                  else "F"
                  end
  end

  # ---- Comparison to Last Week ----
  def compute_comparison
    @comparison = []

    # Trading comparison
    prev_pnl = @prev_trades.sum { |t| t["pnl"].to_f }
    prev_count = @prev_trades.count
    prev_wins = @prev_trades.count { |t| t["pnl"].to_f > 0 }
    prev_win_rate = prev_count > 0 ? (prev_wins.to_f / prev_count * 100).round(1) : 0

    @comparison << { label: "Trades", current: @trade_count, previous: prev_count, format: :number }
    @comparison << { label: "P&L", current: @trade_pnl, previous: prev_pnl, format: :currency }
    @comparison << { label: "Win Rate", current: @trade_win_rate, previous: prev_win_rate, format: :percent }

    # Budget comparison
    prev_income = @prev_transactions.select { |t| t["transaction_type"] == "income" }.sum { |t| t["amount"].to_f }
    prev_spending = @prev_transactions.select { |t| t["transaction_type"] != "income" }.sum { |t| t["amount"].to_f }
    prev_savings = prev_income - prev_spending

    @comparison << { label: "Income", current: @budget_income, previous: prev_income, format: :currency }
    @comparison << { label: "Spending", current: @budget_spending, previous: prev_spending, format: :currency, invert: true }
    @comparison << { label: "Savings", current: @budget_savings, previous: prev_savings, format: :currency }

    # Notes comparison
    prev_notes_count = @prev_notes.count
    prev_notes_words = @prev_notes.sum { |n| (n["word_count"] || n["content"]&.to_s&.split&.count || 0).to_i }

    @comparison << { label: "Notes", current: @notes_count, previous: prev_notes_count, format: :number }
    @comparison << { label: "Words Written", current: @notes_words, previous: prev_notes_words, format: :number }
  end

  # ---- Daily Breakdown ----
  def compute_daily_breakdown
    @daily_breakdown = []
    (@week_start..@week_end).each do |date|
      date_str = date.to_s

      day_trades = @trades.select { |t|
        d = (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 10)
        d == date_str
      }
      day_pnl = day_trades.sum { |t| t["pnl"].to_f }

      day_transactions = @transactions.select { |t|
        (t["transaction_date"])&.to_s&.slice(0, 10) == date_str
      }
      day_spending = day_transactions.select { |t| t["transaction_type"] != "income" }.sum { |t| t["amount"].to_f }

      day_notes = @notes.select { |n|
        d = (n["updated_at"] || n["created_at"])&.to_s&.slice(0, 10)
        d == date_str
      }

      day_journals = @journal_entries.select { |j|
        (j["date"])&.to_s&.slice(0, 10) == date_str
      }

      @daily_breakdown << {
        date: date,
        day_name: date.strftime("%a"),
        trades: day_trades.count,
        pnl: day_pnl,
        transactions: day_transactions.count,
        spending: day_spending,
        notes: day_notes.count,
        words: day_notes.sum { |n| (n["word_count"] || n["content"]&.to_s&.split&.count || 0).to_i },
        journals: day_journals.count,
        is_today: date == Date.current,
        is_future: date > Date.current
      }
    end
  end
end

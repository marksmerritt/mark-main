class HabitTrackerController < ApplicationController
  include ActionView::Helpers::NumberHelper

  HABITS = [
    { key: :logged_trade, name: "Logged a Trade", icon: "candlestick_chart" },
    { key: :wrote_journal, name: "Wrote a Journal Entry", icon: "auto_stories" },
    { key: :wrote_note, name: "Wrote a Note", icon: "description" },
    { key: :reviewed_trades, name: "Reviewed Trades", icon: "rate_review" },
    { key: :stayed_under_budget, name: "Stayed Under Budget", icon: "savings" },
    { key: :exercised_discipline, name: "Exercised Discipline", icon: "shield" }
  ].freeze

  def show
    @days = 30
    @start_date = Date.current - (@days - 1)
    @end_date = Date.current
    @dates = (@start_date..@end_date).to_a

    threads = {}

    if api_token.present?
      threads[:trades] = Thread.new do
        result = api_client.trades(
          start_date: @start_date.to_s,
          end_date: (@end_date + 1.day).to_s,
          per_page: 500
        )
        result.is_a?(Hash) ? (result["trades"] || []) : Array(result)
      rescue => e
        Rails.logger.error("HabitTracker trades error: #{e.message}")
        []
      end
      threads[:journal] = Thread.new do
        result = api_client.journal_entries(
          start_date: @start_date.to_s,
          end_date: @end_date.to_s
        )
        result.is_a?(Hash) ? (result["journal_entries"] || []) : Array(result)
      rescue => e
        Rails.logger.error("HabitTracker journal error: #{e.message}")
        []
      end
      threads[:streaks] = Thread.new do
        api_client.streaks rescue {}
      end
    end

    if notes_api_token.present?
      threads[:notes] = Thread.new do
        result = notes_client.notes(per_page: 200)
        result.is_a?(Hash) ? (result["notes"] || []) : Array(result)
      rescue => e
        Rails.logger.error("HabitTracker notes error: #{e.message}")
        []
      end
    end

    if budget_api_token.present?
      threads[:transactions] = Thread.new do
        result = budget_client.transactions(per_page: 200)
        result.is_a?(Hash) ? (result["transactions"] || result) : Array(result)
      rescue => e
        Rails.logger.error("HabitTracker transactions error: #{e.message}")
        []
      end
    end

    trades = threads[:trades]&.value || []
    trades = trades.select { |t| t.is_a?(Hash) }
    journal_entries = threads[:journal]&.value || []
    journal_entries = journal_entries.select { |e| e.is_a?(Hash) }
    @streaks = threads[:streaks]&.value || {}
    notes = threads[:notes]&.value || []
    notes = notes.select { |n| n.is_a?(Hash) }
    transactions = threads[:transactions]&.value || []
    transactions = transactions.is_a?(Array) ? transactions.select { |t| t.is_a?(Hash) } : []

    # Group data by date
    trades_by_date = group_by_date(trades, "entry_time", "exit_time")
    journal_by_date = group_by_date(journal_entries, "date")
    notes_by_date = group_by_date(notes, "updated_at", "created_at")
    transactions_by_date = group_by_date(transactions, "date", "transaction_date")

    # Calculate daily budget threshold
    total_spending = transactions.sum { |t| t["amount"].to_f.abs }
    days_with_spending = transactions_by_date.keys.count { |d| d >= @start_date && d <= @end_date }
    @daily_budget_threshold = days_with_spending > 0 ? (total_spending / days_with_spending) : 100.0

    # Build daily habit matrix
    @habit_grid = {}
    HABITS.each { |h| @habit_grid[h[:key]] = {} }

    @dates.each do |date|
      day_trades = trades_by_date[date] || []
      day_journal = journal_by_date[date] || []
      day_notes = notes_by_date[date] || []
      day_transactions = transactions_by_date[date] || []

      # 1. Logged a Trade
      @habit_grid[:logged_trade][date] = day_trades.any?

      # 2. Wrote a Journal Entry
      @habit_grid[:wrote_journal][date] = day_journal.any?

      # 3. Wrote a Note
      @habit_grid[:wrote_note][date] = day_notes.any?

      # 4. Reviewed Trades
      @habit_grid[:reviewed_trades][date] = day_trades.any? { |t| t["review_rating"].present? }

      # 5. Stayed Under Budget
      daily_spend = day_transactions.sum { |t| t["amount"].to_f.abs }
      if day_transactions.any?
        @habit_grid[:stayed_under_budget][date] = daily_spend <= @daily_budget_threshold
      else
        @habit_grid[:stayed_under_budget][date] = nil # no data
      end

      # 6. Exercised Discipline - win rate >= 50% or no trades
      if day_trades.any?
        wins = day_trades.count { |t| t["pnl"].to_f > 0 }
        wr = wins.to_f / day_trades.count
        @habit_grid[:exercised_discipline][date] = wr >= 0.5
      else
        @habit_grid[:exercised_discipline][date] = nil # skip day
      end
    end

    # Compute stats for each habit
    @habit_stats = {}
    HABITS.each do |habit|
      grid = @habit_grid[habit[:key]]
      active_days = @dates.select { |d| grid[d] != nil }
      completed_days = @dates.select { |d| grid[d] == true }

      current_streak = compute_current_streak(grid, @dates)
      best_streak = compute_best_streak(grid, @dates)
      completion_rate = active_days.any? ? (completed_days.count.to_f / active_days.count * 100).round(0) : 0

      @habit_stats[habit[:key]] = {
        current_streak: current_streak,
        best_streak: best_streak,
        completion_rate: completion_rate,
        total_count: completed_days.count,
        active_days: active_days.count
      }
    end

    # Discipline Score (0-100)
    total_possible = 0
    total_achieved = 0
    HABITS.each do |habit|
      stats = @habit_stats[habit[:key]]
      total_possible += stats[:active_days]
      total_achieved += stats[:total_count]
    end
    @discipline_score = total_possible > 0 ? (total_achieved.to_f / total_possible * 100).round(0) : 0

    # Today's checklist
    @today = Date.current
    @today_checklist = HABITS.map do |habit|
      status = @habit_grid[habit[:key]][@today]
      {
        name: habit[:name],
        icon: habit[:icon],
        done: status == true,
        skipped: status.nil?
      }
    end

    @habits = HABITS
  end

  private

  def group_by_date(records, *date_fields)
    grouped = Hash.new { |h, k| h[k] = [] }
    records.each do |record|
      date_str = nil
      date_fields.each do |field|
        date_str = record[field]&.to_s&.slice(0, 10)
        break if date_str.present?
      end
      next unless date_str.present?
      date = Date.parse(date_str) rescue nil
      next unless date
      grouped[date] << record
    end
    grouped
  end

  def compute_current_streak(grid, dates)
    streak = 0
    dates.reverse_each do |date|
      val = grid[date]
      if val == true
        streak += 1
      elsif val == false
        break
      end
      # nil (no data) is skipped
    end
    streak
  end

  def compute_best_streak(grid, dates)
    best = 0
    current = 0
    dates.each do |date|
      val = grid[date]
      if val == true
        current += 1
        best = current if current > best
      elsif val == false
        current = 0
      end
      # nil (no data) is skipped
    end
    best
  end
end

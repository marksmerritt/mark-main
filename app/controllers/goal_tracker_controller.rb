class GoalTrackerController < ApplicationController
  include ActionView::Helpers::NumberHelper

  before_action :require_api_connection

  def show
    threads = {}

    # Trading data
    if api_token.present?
      threads[:trading_overview] = Thread.new { api_client.overview rescue {} }
      threads[:trading_streaks] = Thread.new { api_client.streaks rescue {} }
    end

    # Budget data
    if budget_api_token.present?
      threads[:budget_goals] = Thread.new {
        result = budget_client.goals(status: "active") rescue []
        result.is_a?(Array) ? result : (result.is_a?(Hash) ? (result["goals"] || []) : [])
      }
      threads[:debt_overview] = Thread.new { budget_client.debt_overview rescue {} }
      threads[:budget_overview] = Thread.new { budget_client.budget_overview rescue {} }
    end

    # Notes data
    if notes_api_token.present?
      threads[:notes_stats] = Thread.new { notes_client.stats rescue {} }
      threads[:notes_recent] = Thread.new {
        result = notes_client.notes(per_page: 500) rescue []
        result.is_a?(Hash) ? (result["notes"] || []) : Array(result)
      }
    end

    # Collect results
    trading_overview = threads[:trading_overview]&.value || {}
    trading_overview = {} unless trading_overview.is_a?(Hash)
    trading_streaks = threads[:trading_streaks]&.value || {}
    trading_streaks = {} unless trading_streaks.is_a?(Hash)

    budget_goals = threads[:budget_goals]&.value || []
    debt_overview = threads[:debt_overview]&.value || {}
    debt_overview = {} unless debt_overview.is_a?(Hash)
    budget_overview = threads[:budget_overview]&.value || {}
    budget_overview = {} unless budget_overview.is_a?(Hash)

    notes_stats = threads[:notes_stats]&.value || {}
    notes_stats = {} unless notes_stats.is_a?(Hash)
    notes_recent = threads[:notes_recent]&.value || []

    # Build unified goals
    @goals = []

    # --- Trading Goals ---
    if api_token.present?
      total_pnl = trading_overview["total_pnl"].to_f
      win_rate = trading_overview["win_rate"].to_f
      total_trades = trading_overview["total_trades"].to_i
      raw_pnl = trading_overview["daily_pnl"] || {}
      daily_pnl = raw_pnl.is_a?(Array) ? raw_pnl.to_h : raw_pnl
      max_drawdown = trading_overview["max_drawdown"].to_f.abs

      # Monthly P&L target
      monthly_pnl = daily_pnl.select { |d, _| Date.parse(d) >= Date.current.beginning_of_month rescue false }.values.sum(&:to_f)
      monthly_target = 2000.0
      monthly_progress = monthly_target > 0 ? [(monthly_pnl / monthly_target * 100).round(1), 100].min : 0
      @goals << {
        name: "Monthly P&L Target",
        category: "Trading",
        icon: "payments",
        current_value: monthly_pnl,
        target_value: monthly_target,
        progress_pct: [monthly_progress, 0].max,
        status: goal_status(monthly_progress, 75),
        color: "#1565c0",
        format: :currency
      }

      # Win rate target
      win_target = 55.0
      win_progress = win_target > 0 ? [(win_rate / win_target * 100).round(1), 100].min : 0
      @goals << {
        name: "Win Rate Target",
        category: "Trading",
        icon: "emoji_events",
        current_value: win_rate,
        target_value: win_target,
        progress_pct: [win_progress, 0].max,
        status: goal_status(win_progress, 80),
        color: "#2e7d32",
        format: :pct
      }

      # Max drawdown target (lower is better)
      drawdown_limit = 500.0
      drawdown_progress = drawdown_limit > 0 ? [((drawdown_limit - max_drawdown) / drawdown_limit * 100).round(1), 0].max : 100
      drawdown_status = if max_drawdown <= drawdown_limit * 0.5
                          :completed
                        elsif max_drawdown <= drawdown_limit * 0.75
                          :on_track
                        elsif max_drawdown <= drawdown_limit
                          :at_risk
                        else
                          :behind
                        end
      @goals << {
        name: "Max Drawdown Limit",
        category: "Trading",
        icon: "shield",
        current_value: max_drawdown,
        target_value: drawdown_limit,
        progress_pct: [drawdown_progress, 0].max,
        status: drawdown_status,
        color: "#e65100",
        format: :currency,
        inverted: true
      }

      # Trade count target
      trade_target = 50
      trade_progress = trade_target > 0 ? [(total_trades.to_f / trade_target * 100).round(1), 100].min : 0
      @goals << {
        name: "Trade Count Target",
        category: "Trading",
        icon: "bar_chart",
        current_value: total_trades,
        target_value: trade_target,
        progress_pct: [trade_progress, 0].max,
        status: goal_status(trade_progress, 60),
        color: "#6a1b9a",
        format: :number
      }
    end

    # --- Budget Goals ---
    if budget_api_token.present?
      # Savings goal from budget goals
      active_budget_goals = budget_goals.select { |g| g.is_a?(Hash) }
      savings_goals = active_budget_goals.select { |g| g["goal_type"] == "savings" || g["category"] == "savings" }
      if savings_goals.any?
        sg = savings_goals.first
        savings_current = sg["current_amount"].to_f
        savings_target = sg["target_amount"].to_f
        savings_progress = savings_target > 0 ? [(savings_current / savings_target * 100).round(1), 100].min : 0
      else
        savings_current = 0
        savings_target = 5000.0
        savings_progress = 0
      end
      @goals << {
        name: "Savings Goal",
        category: "Budget",
        icon: "savings",
        current_value: savings_current,
        target_value: savings_target,
        progress_pct: [savings_progress, 0].max,
        status: goal_status(savings_progress, 50),
        color: "#0d904f",
        format: :currency
      }

      # Debt payoff target
      debts = debt_overview.is_a?(Hash) ? (debt_overview["debts"] || debt_overview["debt_accounts"] || []) : []
      total_debt = debts.is_a?(Array) ? debts.sum { |d| d.is_a?(Hash) ? d["current_balance"].to_f : 0 } : 0
      original_debt = debts.is_a?(Array) ? debts.sum { |d| d.is_a?(Hash) ? (d["original_balance"] || d["current_balance"]).to_f : 0 } : 0
      debt_paid = [original_debt - total_debt, 0].max
      debt_progress = original_debt > 0 ? [(debt_paid / original_debt * 100).round(1), 100].min : 100
      @goals << {
        name: "Debt Payoff",
        category: "Budget",
        icon: "credit_card_off",
        current_value: debt_paid,
        target_value: original_debt,
        progress_pct: [debt_progress, 0].max,
        status: goal_status(debt_progress, 40),
        color: "#c62828",
        format: :currency
      }

      # Spending limit
      budget_spent = budget_overview["total_spent"].to_f
      budget_limit = budget_overview["total_budgeted"].to_f
      budget_limit = 3000.0 if budget_limit == 0
      remaining = [budget_limit - budget_spent, 0].max
      spending_progress = budget_limit > 0 ? [((budget_limit - budget_spent) / budget_limit * 100).round(1), 0].max : 100
      spending_status = if budget_spent <= budget_limit * 0.7
                          :on_track
                        elsif budget_spent <= budget_limit * 0.9
                          :at_risk
                        elsif budget_spent <= budget_limit
                          :behind
                        else
                          :behind
                        end
      @goals << {
        name: "Monthly Spending Limit",
        category: "Budget",
        icon: "account_balance_wallet",
        current_value: budget_spent,
        target_value: budget_limit,
        progress_pct: [spending_progress, 0].max,
        status: spending_status,
        color: "#ef6c00",
        format: :currency,
        inverted: true
      }

      # Emergency fund target
      emergency_goals = active_budget_goals.select { |g| g["goal_type"] == "emergency" || (g["name"] || "").downcase.include?("emergency") }
      if emergency_goals.any?
        eg = emergency_goals.first
        emerg_current = eg["current_amount"].to_f
        emerg_target = eg["target_amount"].to_f
      else
        emerg_current = 0
        emerg_target = 10000.0
      end
      emerg_progress = emerg_target > 0 ? [(emerg_current / emerg_target * 100).round(1), 100].min : 0
      @goals << {
        name: "Emergency Fund",
        category: "Budget",
        icon: "health_and_safety",
        current_value: emerg_current,
        target_value: emerg_target,
        progress_pct: [emerg_progress, 0].max,
        status: goal_status(emerg_progress, 30),
        color: "#1565c0",
        format: :currency
      }
    end

    # --- Writing Goals ---
    if notes_api_token.present?
      total_notes = (notes_stats["total_notes"] || notes_stats["count"] || 0).to_i
      this_week_notes = (notes_stats["this_week"] || notes_stats["recent_count"] || 0).to_i
      total_words = (notes_stats["total_words"] || notes_stats["word_count"] || 0).to_i

      # Compute writing streak from recent notes
      notes_with_dates = notes_recent.select { |n| n.is_a?(Hash) }
      sorted_dates = notes_with_dates.filter_map { |n|
        Date.parse(n["created_at"] || n["updated_at"] || "") rescue nil
      }.uniq.sort
      writing_streak = 0
      if sorted_dates.any?
        current_date = Date.current
        while sorted_dates.include?(current_date)
          writing_streak += 1
          current_date -= 1
        end
      end

      # Notes per week
      notes_week_target = 5
      notes_week_progress = notes_week_target > 0 ? [(this_week_notes.to_f / notes_week_target * 100).round(1), 100].min : 0
      @goals << {
        name: "Notes Per Week",
        category: "Writing",
        icon: "edit_note",
        current_value: this_week_notes,
        target_value: notes_week_target,
        progress_pct: [notes_week_progress, 0].max,
        status: goal_status(notes_week_progress, 60),
        color: "#9c27b0",
        format: :number
      }

      # Total word count
      word_count_target = 50000
      word_progress = word_count_target > 0 ? [(total_words.to_f / word_count_target * 100).round(1), 100].min : 0
      @goals << {
        name: "Total Word Count",
        category: "Writing",
        icon: "text_fields",
        current_value: total_words,
        target_value: word_count_target,
        progress_pct: [word_progress, 0].max,
        status: goal_status(word_progress, 30),
        color: "#00838f",
        format: :number
      }

      # Journal streak
      streak_target = 7
      streak_progress = streak_target > 0 ? [(writing_streak.to_f / streak_target * 100).round(1), 100].min : 0
      @goals << {
        name: "Journal Streak",
        category: "Writing",
        icon: "local_fire_department",
        current_value: writing_streak,
        target_value: streak_target,
        progress_pct: [streak_progress, 0].max,
        status: goal_status(streak_progress, 50),
        color: "#e65100",
        format: :streak
      }
    end

    # Summary stats
    @completed = @goals.count { |g| g[:status] == :completed }
    @total_goals = @goals.count
    @overall_progress = @total_goals > 0 ? (@goals.sum { |g| g[:progress_pct] } / @total_goals).round(0) : 0
    @on_track = @goals.count { |g| g[:status] == :on_track }
    @at_risk = @goals.count { |g| g[:status] == :at_risk }
    @behind = @goals.count { |g| g[:status] == :behind }

    # Group by category
    @by_category = @goals.group_by { |g| g[:category] }

    # Next milestone: the closest goal to completion that isn't done
    incomplete = @goals.select { |g| g[:status] != :completed }.sort_by { |g| -g[:progress_pct] }
    @next_milestone = incomplete.first

    # Best streak across products
    trading_streak = trading_streaks.is_a?(Hash) ? (trading_streaks.dig("current_streak", "count") || trading_streaks["current_streak"]).to_i : 0
    @best_streak = { type: "Trading", value: trading_streak }
    if notes_api_token.present?
      writing_streak_val = @goals.find { |g| g[:name] == "Journal Streak" }&.dig(:current_value) || 0
      if writing_streak_val > trading_streak
        @best_streak = { type: "Writing", value: writing_streak_val }
      end
    end
  end

  private

  def goal_status(progress, on_track_threshold)
    if progress >= 100
      :completed
    elsif progress >= on_track_threshold
      :on_track
    elsif progress >= on_track_threshold * 0.5
      :at_risk
    else
      :behind
    end
  end
end

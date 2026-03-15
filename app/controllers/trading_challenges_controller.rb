class TradingChallengesController < ApplicationController
  before_action :require_api_connection

  include ActionView::Helpers::NumberHelper

  STREAK_MILESTONES = [3, 5, 7, 10, 15, 20].freeze
  LEVELS = %w[Bronze Silver Gold Platinum Diamond].freeze

  def show
    threads = {}
    threads[:trades] = Thread.new { api_client.trades(per_page: 1000, status: "closed") }
    threads[:journal] = Thread.new { api_client.journal_entries(per_page: 1000) }
    threads[:streaks] = Thread.new { api_client.streaks rescue {} }

    trade_result = threads[:trades].value
    @trades = trade_result.is_a?(Hash) ? (trade_result["trades"] || []) : Array(trade_result)
    @trades = @trades.select { |t| t.is_a?(Hash) && t["pnl"].present? }
    @trades = @trades.sort_by { |t| t["exit_time"] || t["entry_time"] || "" }

    journal_result = threads[:journal].value
    @entries = journal_result.is_a?(Hash) ? (journal_result["journal_entries"] || []) : Array(journal_result)
    @entries = @entries.select { |e| e.is_a?(Hash) }

    @streaks_data = threads[:streaks].value || {}

    @challenges = []
    @recent_milestones = []

    compute_win_streak
    compute_profit_streak
    compute_discipline_streak
    compute_journal_streak
    compute_green_week
    compute_risk_manager_badge
    compute_consistency_badge
    compute_diversification_badge

    # Trader level based on completed challenges
    completed_count = @challenges.count { |c| c[:is_completed] }
    level_index = case completed_count
                  when 7..Float::INFINITY then 4
                  when 5..6 then 3
                  when 3..4 then 2
                  when 1..2 then 1
                  else 0
                  end
    @trader_level = LEVELS[level_index]
    @trader_level_index = level_index
    @completed_count = completed_count
    @total_challenges = @challenges.count

    # Progress to next level
    thresholds = [0, 1, 3, 5, 7]
    if level_index < 4
      next_threshold = thresholds[level_index + 1]
      current_threshold = thresholds[level_index]
      range = next_threshold - current_threshold
      progress_in_range = completed_count - current_threshold
      @level_progress = range > 0 ? (progress_in_range.to_f / range * 100).round(0).clamp(0, 100) : 100
      @next_level = LEVELS[level_index + 1]
    else
      @level_progress = 100
      @next_level = nil
    end

    @active_streaks = @challenges.count { |c| c[:current_progress] > 0 && !c[:is_completed] }
    @badges_earned = completed_count
    @best_win_streak = @challenges.find { |c| c[:name] == "Win Streak" }&.dig(:best_ever) || 0

    @recent_milestones = @recent_milestones.sort_by { |m| m[:date] || "" }.reverse.first(8)
  end

  private

  def compute_win_streak
    return add_empty_challenge("Win Streak", "emoji_events", "Consecutive winning trades") if @trades.empty?

    current_streak = 0
    best_streak = 0
    temp_streak = 0

    @trades.reverse_each do |t|
      if t["pnl"].to_f > 0
        temp_streak += 1
      else
        break
      end
    end
    current_streak = temp_streak

    temp_streak = 0
    @trades.each do |t|
      if t["pnl"].to_f > 0
        temp_streak += 1
        best_streak = temp_streak if temp_streak > best_streak
      else
        temp_streak = 0
      end
    end

    next_milestone = STREAK_MILESTONES.find { |m| m > current_streak } || STREAK_MILESTONES.last
    is_completed = current_streak >= STREAK_MILESTONES.last

    if best_streak >= 3
      @recent_milestones << { icon: "emoji_events", text: "Best win streak: #{best_streak} trades", date: nil, color: "#f9a825" }
    end

    @challenges << {
      name: "Win Streak",
      icon: "emoji_events",
      description: "Win #{next_milestone} trades in a row",
      current_progress: current_streak,
      target: next_milestone,
      is_completed: is_completed,
      best_ever: best_streak,
      category: :streak
    }
  end

  def compute_profit_streak
    return add_empty_challenge("Profit Streak", "trending_up", "Consecutive profitable days") if @trades.empty?

    daily_pnl = {}
    @trades.each do |t|
      date = (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 10)
      next unless date
      daily_pnl[date] ||= 0
      daily_pnl[date] += t["pnl"].to_f
    end

    sorted_days = daily_pnl.keys.sort
    current_streak = 0
    best_streak = 0
    temp_streak = 0

    sorted_days.reverse_each do |day|
      if daily_pnl[day] > 0
        temp_streak += 1
      else
        break
      end
    end
    current_streak = temp_streak

    temp_streak = 0
    sorted_days.each do |day|
      if daily_pnl[day] > 0
        temp_streak += 1
        best_streak = temp_streak if temp_streak > best_streak
      else
        temp_streak = 0
      end
    end

    next_milestone = STREAK_MILESTONES.find { |m| m > current_streak } || STREAK_MILESTONES.last

    @challenges << {
      name: "Profit Streak",
      icon: "trending_up",
      description: "#{next_milestone} consecutive profitable days",
      current_progress: current_streak,
      target: next_milestone,
      is_completed: current_streak >= STREAK_MILESTONES.last,
      best_ever: best_streak,
      category: :streak
    }
  end

  def compute_discipline_streak
    return add_empty_challenge("Discipline Streak", "shield", "Consecutive trades with stop loss") if @trades.empty?

    current_streak = 0
    best_streak = 0
    temp_streak = 0

    @trades.reverse_each do |t|
      if t["stop_loss"].to_f > 0
        temp_streak += 1
      else
        break
      end
    end
    current_streak = temp_streak

    temp_streak = 0
    @trades.each do |t|
      if t["stop_loss"].to_f > 0
        temp_streak += 1
        best_streak = temp_streak if temp_streak > best_streak
      else
        temp_streak = 0
      end
    end

    next_milestone = STREAK_MILESTONES.find { |m| m > current_streak } || STREAK_MILESTONES.last

    @challenges << {
      name: "Discipline Streak",
      icon: "shield",
      description: "#{next_milestone} consecutive trades with stop loss set",
      current_progress: current_streak,
      target: next_milestone,
      is_completed: current_streak >= STREAK_MILESTONES.last,
      best_ever: best_streak,
      category: :streak
    }
  end

  def compute_journal_streak
    journal_dates = @entries.filter_map { |e| e["date"]&.to_s&.slice(0, 10) }.uniq.sort

    if journal_dates.empty?
      return add_empty_challenge("Journal Streak", "edit_note", "Consecutive days with journal entries")
    end

    current_streak = 0
    best_streak = 0
    today = Date.today

    # Current streak: count backwards from today
    temp_streak = 0
    check_date = today
    loop do
      if journal_dates.include?(check_date.to_s)
        temp_streak += 1
        check_date -= 1
      else
        break
      end
    end
    current_streak = temp_streak

    # Also check API streaks data
    api_streak = @streaks_data.is_a?(Hash) ? (@streaks_data["journal_streak"] || @streaks_data["current_journal_streak"] || 0).to_i : 0
    current_streak = [current_streak, api_streak].max

    # Best ever
    temp_streak = 0
    prev_date = nil
    journal_dates.each do |d|
      date = Date.parse(d) rescue nil
      next unless date
      if prev_date && (date - prev_date).to_i == 1
        temp_streak += 1
      else
        temp_streak = 1
      end
      best_streak = temp_streak if temp_streak > best_streak
      prev_date = date
    end

    api_best = @streaks_data.is_a?(Hash) ? (@streaks_data["longest_journal_streak"] || 0).to_i : 0
    best_streak = [best_streak, api_best].max

    next_milestone = STREAK_MILESTONES.find { |m| m > current_streak } || STREAK_MILESTONES.last

    if current_streak >= 7
      @recent_milestones << { icon: "edit_note", text: "Journal streak: #{current_streak} days!", date: today.to_s, color: "var(--primary)" }
    end

    @challenges << {
      name: "Journal Streak",
      icon: "edit_note",
      description: "Journal #{next_milestone} consecutive days",
      current_progress: current_streak,
      target: next_milestone,
      is_completed: current_streak >= STREAK_MILESTONES.last,
      best_ever: best_streak,
      category: :streak
    }
  end

  def compute_green_week
    return add_empty_challenge("Green Week Challenge", "date_range", "Consecutive weeks with positive P&L") if @trades.empty?

    weekly_pnl = {}
    @trades.each do |t|
      date = Date.parse((t["exit_time"] || t["entry_time"]).to_s.slice(0, 10)) rescue nil
      next unless date
      week_start = date.beginning_of_week.to_s
      weekly_pnl[week_start] ||= 0
      weekly_pnl[week_start] += t["pnl"].to_f
    end

    sorted_weeks = weekly_pnl.keys.sort
    current_streak = 0
    best_streak = 0
    temp_streak = 0

    sorted_weeks.reverse_each do |w|
      if weekly_pnl[w] > 0
        temp_streak += 1
      else
        break
      end
    end
    current_streak = temp_streak

    temp_streak = 0
    sorted_weeks.each do |w|
      if weekly_pnl[w] > 0
        temp_streak += 1
        best_streak = temp_streak if temp_streak > best_streak
      else
        temp_streak = 0
      end
    end

    target = 4

    if best_streak >= 4
      @recent_milestones << { icon: "date_range", text: "#{best_streak} green weeks in a row!", date: nil, color: "var(--positive)" }
    end

    @challenges << {
      name: "Green Week Challenge",
      icon: "date_range",
      description: "4 consecutive weeks with positive P&L",
      current_progress: current_streak,
      target: target,
      is_completed: current_streak >= target,
      best_ever: best_streak,
      category: :challenge
    }
  end

  def compute_risk_manager_badge
    return add_empty_challenge("Risk Manager", "admin_panel_settings", "Trades with proper stop loss and position sizing") if @trades.empty?

    trades_with_stop = @trades.count { |t| t["stop_loss"].to_f > 0 }
    trades_with_sizing = @trades.count { |t|
      entry = t["entry_price"].to_f
      qty = t["quantity"].to_f
      entry > 0 && qty > 0
    }
    managed = @trades.count { |t| t["stop_loss"].to_f > 0 && t["entry_price"].to_f > 0 && t["quantity"].to_f > 0 }
    pct = @trades.any? ? (managed.to_f / @trades.count * 100).round(0) : 0
    target = 80

    if pct >= target
      @recent_milestones << { icon: "admin_panel_settings", text: "Risk Manager badge earned (#{pct}%)", date: nil, color: "var(--primary)" }
    end

    @challenges << {
      name: "Risk Manager",
      icon: "admin_panel_settings",
      description: "#{target}%+ of trades with stop loss and position sizing",
      current_progress: pct,
      target: target,
      is_completed: pct >= target,
      best_ever: pct,
      category: :badge
    }
  end

  def compute_consistency_badge
    return add_empty_challenge("Consistency Badge", "straighten", "Monthly win rate above 50% for consecutive months") if @trades.empty?

    monthly_stats = {}
    @trades.each do |t|
      month = (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 7)
      next unless month
      monthly_stats[month] ||= { wins: 0, total: 0 }
      monthly_stats[month][:total] += 1
      monthly_stats[month][:wins] += 1 if t["pnl"].to_f > 0
    end

    sorted_months = monthly_stats.keys.sort
    current_streak = 0
    best_streak = 0
    temp_streak = 0

    sorted_months.reverse_each do |m|
      stats = monthly_stats[m]
      win_rate = stats[:total] > 0 ? (stats[:wins].to_f / stats[:total] * 100) : 0
      if win_rate >= 50
        temp_streak += 1
      else
        break
      end
    end
    current_streak = temp_streak

    temp_streak = 0
    sorted_months.each do |m|
      stats = monthly_stats[m]
      win_rate = stats[:total] > 0 ? (stats[:wins].to_f / stats[:total] * 100) : 0
      if win_rate >= 50
        temp_streak += 1
        best_streak = temp_streak if temp_streak > best_streak
      else
        temp_streak = 0
      end
    end

    target = 3

    if best_streak >= target
      @recent_milestones << { icon: "straighten", text: "Consistent trader: #{best_streak} months above 50% WR", date: nil, color: "var(--positive)" }
    end

    @challenges << {
      name: "Consistency Badge",
      icon: "straighten",
      description: "Win rate above 50% for #{target}+ consecutive months",
      current_progress: current_streak,
      target: target,
      is_completed: current_streak >= target,
      best_ever: best_streak,
      category: :badge
    }
  end

  def compute_diversification_badge
    return add_empty_challenge("Diversification Badge", "workspaces", "Trade 5+ different symbols in a month") if @trades.empty?

    current_month = Date.today.strftime("%Y-%m")
    symbols_this_month = @trades.select { |t|
      month = (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 7)
      month == current_month
    }.filter_map { |t| t["symbol"] }.uniq

    # Best ever month
    monthly_symbols = {}
    @trades.each do |t|
      month = (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 7)
      next unless month
      sym = t["symbol"]
      next unless sym
      monthly_symbols[month] ||= Set.new
      monthly_symbols[month] << sym
    end
    best_ever = monthly_symbols.values.map(&:count).max || 0

    current_count = symbols_this_month.count
    target = 5

    if current_count >= target
      @recent_milestones << { icon: "workspaces", text: "Diversified: #{current_count} symbols traded this month", date: Date.today.to_s, color: "var(--primary)" }
    end

    @challenges << {
      name: "Diversification Badge",
      icon: "workspaces",
      description: "Trade 5+ different symbols in a month",
      current_progress: current_count,
      target: target,
      is_completed: current_count >= target,
      best_ever: best_ever,
      category: :badge
    }
  end

  def add_empty_challenge(name, icon, description)
    @challenges << {
      name: name,
      icon: icon,
      description: description,
      current_progress: 0,
      target: 1,
      is_completed: false,
      best_ever: 0,
      category: :streak
    }
  end
end

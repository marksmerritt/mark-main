class AchievementsController < ApplicationController
  before_action :require_api_connection

  include ActionView::Helpers::NumberHelper

  def show
    threads = {}

    threads[:trades] = Thread.new do
      result = api_client.trades(per_page: 2000, status: "closed")
      trades = result.is_a?(Hash) ? (result["trades"] || []) : Array(result)
      trades.select { |t| t.is_a?(Hash) }
    rescue => e
      Rails.logger.error("achievements trades: #{e.message}")
      []
    end

    threads[:overview] = Thread.new do
      api_client.overview || {}
    rescue => e
      Rails.logger.error("achievements overview: #{e.message}")
      {}
    end

    threads[:streaks] = Thread.new do
      api_client.streaks || {}
    rescue => e
      Rails.logger.error("achievements streaks: #{e.message}")
      {}
    end

    threads[:journal] = Thread.new do
      result = api_client.journal_entries(per_page: 1000)
      entries = result.is_a?(Hash) ? (result["journal_entries"] || []) : Array(result)
      entries.select { |e| e.is_a?(Hash) }
    rescue => e
      Rails.logger.error("achievements journal: #{e.message}")
      []
    end

    @trades = threads[:trades].value
    @overview = threads[:overview].value || {}
    @overview = {} unless @overview.is_a?(Hash)
    @streaks = threads[:streaks].value || {}
    @streaks = {} unless @streaks.is_a?(Hash)
    @entries = threads[:journal].value

    # Compute derived data
    @trades = @trades.sort_by { |t| t["exit_time"] || t["entry_time"] || "" }
    pnls = @trades.map { |t| t["pnl"].to_f }
    wins = @trades.select { |t| t["pnl"].to_f > 0 }
    losses = @trades.select { |t| t["pnl"].to_f < 0 }
    total_pnl = pnls.sum
    total_count = @trades.count
    win_rate = total_count > 0 ? (wins.count.to_f / total_count * 100) : 0
    reviewed_trades = @trades.count { |t| t["reviewed"] || t["trade_grade"].present? }
    trades_with_stops = @trades.count { |t| t["stop_loss"].to_f > 0 }

    # Daily P&L
    daily_pnl = {}
    @trades.each do |t|
      date = (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 10)
      next unless date
      daily_pnl[date] ||= 0
      daily_pnl[date] += t["pnl"].to_f
    end
    best_day_pnl = daily_pnl.values.max || 0

    # Win streak calculation
    max_win_streak = 0
    current_win_streak = 0
    @trades.each do |t|
      if t["pnl"].to_f > 0
        current_win_streak += 1
        max_win_streak = current_win_streak if current_win_streak > max_win_streak
      else
        current_win_streak = 0
      end
    end

    # Consecutive wins from most recent
    recent_win_streak = 0
    @trades.reverse_each do |t|
      if t["pnl"].to_f > 0
        recent_win_streak += 1
      else
        break
      end
    end

    # R:R calculation
    trades_with_rr = @trades.select { |t| t["stop_loss"].to_f > 0 && t["take_profit"].to_f > 0 && t["entry_price"].to_f > 0 }
    rr_ratios = trades_with_rr.map do |t|
      entry = t["entry_price"].to_f
      stop = t["stop_loss"].to_f
      target_price = t["take_profit"].to_f
      risk = (entry - stop).abs
      reward = (target_price - entry).abs
      risk > 0 ? reward / risk : 0
    end
    trades_with_good_rr = rr_ratios.count { |r| r >= 2.0 }

    # Max drawdown
    running = 0
    peak = 0
    max_dd = 0
    @trades.each do |t|
      running += t["pnl"].to_f
      peak = running if running > peak
      dd = peak > 0 ? ((peak - running) / peak * 100) : 0
      max_dd = dd if dd > max_dd
    end

    # Journal streak
    journal_dates = @entries.filter_map { |e| e["date"]&.to_s&.slice(0, 10) }.uniq.sort
    journal_streak = 0
    if journal_dates.any?
      check_date = Date.today
      loop do
        if journal_dates.include?(check_date.to_s)
          journal_streak += 1
          check_date -= 1
        else
          break
        end
      end
    end
    api_journal_streak = @streaks.is_a?(Hash) ? (@streaks["journal_streak"] || @streaks["current_journal_streak"] || 0).to_i : 0
    journal_streak = [journal_streak, api_journal_streak].max

    # Trades journaled this week
    week_start = Date.today.beginning_of_week.to_s
    week_end = Date.today.end_of_week.to_s
    trades_this_week = @trades.select do |t|
      d = (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 10)
      d && d >= week_start && d <= week_end
    end
    journal_dates_this_week = @entries.filter_map { |e| e["date"]&.to_s&.slice(0, 10) }
                                       .select { |d| d >= week_start && d <= week_end }
                                       .uniq
    trading_days_this_week = trades_this_week.filter_map { |t| (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 10) }.uniq
    all_journaled_this_week = trading_days_this_week.any? && trading_days_this_week.all? { |d| journal_dates_this_week.include?(d) }

    # Trading day streak (for 7-day and 30-day)
    trading_streak = @streaks.is_a?(Hash) ? (@streaks["trading_streak"] || @streaks["current_trading_streak"] || 0).to_i : 0

    # Build achievements
    @achievements = build_achievements(
      total_count: total_count,
      total_pnl: total_pnl,
      win_rate: win_rate,
      wins_count: wins.count,
      best_day_pnl: best_day_pnl,
      max_win_streak: max_win_streak,
      recent_win_streak: recent_win_streak,
      trades_with_stops: trades_with_stops,
      trades_with_good_rr: trades_with_good_rr,
      max_drawdown: max_dd,
      reviewed_trades: reviewed_trades,
      journal_streak: journal_streak,
      trading_streak: trading_streak,
      all_journaled_this_week: all_journaled_this_week,
      journal_dates: journal_dates,
      trades: @trades,
      daily_pnl: daily_pnl
    )

    @earned_count = @achievements.count { |a| a[:earned] }
    @total_achievements = @achievements.count
    @achievement_score = @total_achievements > 0 ? (@earned_count.to_f / @total_achievements * 100).round(0) : 0

    # Categories
    @categories = @achievements.map { |a| a[:category] }.uniq
    @by_category = @achievements.group_by { |a| a[:category] }

    # Next achievements (closest to being earned but not yet earned)
    @next_achievements = @achievements
      .reject { |a| a[:earned] }
      .sort_by { |a| -(a[:progress] || 0) }
      .first(3)
  end

  private

  def build_achievements(data)
    achievements = []

    # ── Getting Started ──────────────────────────────────────
    achievements << {
      id: "first_trade",
      name: "First Trade",
      description: "Log your first trade",
      icon: "add_circle_outline",
      category: "Getting Started",
      earned: data[:total_count] >= 1,
      progress: [data[:total_count], 1].min * 100,
      earned_date: data[:total_count] >= 1 ? estimate_date(data[:trades], 0) : nil
    }

    achievements << {
      id: "first_win",
      name: "First Win",
      description: "Close your first winning trade",
      icon: "thumb_up",
      category: "Getting Started",
      earned: data[:wins_count] >= 1,
      progress: [data[:wins_count], 1].min * 100,
      earned_date: data[:wins_count] >= 1 ? first_win_date(data[:trades]) : nil
    }

    first_journal = data[:journal_dates].any?
    achievements << {
      id: "first_journal",
      name: "First Journal Entry",
      description: "Write your first journal entry",
      icon: "edit_note",
      category: "Getting Started",
      earned: first_journal,
      progress: first_journal ? 100 : 0,
      earned_date: first_journal ? data[:journal_dates].first : nil
    }

    achievements << {
      id: "first_review",
      name: "First Review",
      description: "Review your first trade",
      icon: "rate_review",
      category: "Getting Started",
      earned: data[:reviewed_trades] >= 1,
      progress: [data[:reviewed_trades], 1].min * 100,
      earned_date: data[:reviewed_trades] >= 1 ? estimate_review_date(data[:trades]) : nil
    }

    # ── Consistency ──────────────────────────────────────────
    achievements << {
      id: "streak_7",
      name: "7-Day Streak",
      description: "Trade 7 days in a row",
      icon: "local_fire_department",
      category: "Consistency",
      earned: data[:trading_streak] >= 7,
      progress: data[:trading_streak] > 0 ? [(data[:trading_streak].to_f / 7 * 100).round(0), 100].min : active_days_progress(data[:daily_pnl], 7),
      earned_date: nil
    }

    achievements << {
      id: "streak_30",
      name: "30-Day Streak",
      description: "Trade 30 days in a row",
      icon: "whatshot",
      category: "Consistency",
      earned: data[:trading_streak] >= 30,
      progress: data[:trading_streak] > 0 ? [(data[:trading_streak].to_f / 30 * 100).round(0), 100].min : active_days_progress(data[:daily_pnl], 30),
      earned_date: nil
    }

    achievements << {
      id: "trades_100",
      name: "Century Club",
      description: "Complete 100 trades",
      icon: "military_tech",
      category: "Consistency",
      earned: data[:total_count] >= 100,
      progress: [(data[:total_count].to_f / 100 * 100).round(0), 100].min,
      earned_date: data[:total_count] >= 100 ? estimate_date(data[:trades], 99) : nil
    }

    achievements << {
      id: "trades_500",
      name: "Veteran Trader",
      description: "Complete 500 trades",
      icon: "workspace_premium",
      category: "Consistency",
      earned: data[:total_count] >= 500,
      progress: [(data[:total_count].to_f / 500 * 100).round(0), 100].min,
      earned_date: data[:total_count] >= 500 ? estimate_date(data[:trades], 499) : nil
    }

    # ── Performance ──────────────────────────────────────────
    achievements << {
      id: "day_100",
      name: "$100 Day",
      description: "Earn $100+ in a single day",
      icon: "paid",
      category: "Performance",
      earned: data[:best_day_pnl] >= 100,
      progress: [(data[:best_day_pnl].to_f / 100 * 100).round(0), 100].min,
      earned_date: data[:best_day_pnl] >= 100 ? first_day_above(data[:daily_pnl], 100) : nil
    }

    achievements << {
      id: "day_500",
      name: "$500 Day",
      description: "Earn $500+ in a single day",
      icon: "payments",
      category: "Performance",
      earned: data[:best_day_pnl] >= 500,
      progress: [(data[:best_day_pnl].to_f / 500 * 100).round(0), 100].min,
      earned_date: data[:best_day_pnl] >= 500 ? first_day_above(data[:daily_pnl], 500) : nil
    }

    achievements << {
      id: "day_1000",
      name: "$1,000 Day",
      description: "Earn $1,000+ in a single day",
      icon: "diamond",
      category: "Performance",
      earned: data[:best_day_pnl] >= 1000,
      progress: [(data[:best_day_pnl].to_f / 1000 * 100).round(0), 100].min,
      earned_date: data[:best_day_pnl] >= 1000 ? first_day_above(data[:daily_pnl], 1000) : nil
    }

    achievements << {
      id: "win_streak_10",
      name: "10 Consecutive Wins",
      description: "Win 10 trades in a row",
      icon: "local_fire_department",
      category: "Performance",
      earned: data[:max_win_streak] >= 10,
      progress: [(data[:max_win_streak].to_f / 10 * 100).round(0), 100].min,
      earned_date: nil
    }

    achievements << {
      id: "win_rate_60",
      name: "60% Win Rate",
      description: "Achieve a 60%+ win rate (min 20 trades)",
      icon: "trending_up",
      category: "Performance",
      earned: data[:total_count] >= 20 && data[:win_rate] >= 60,
      progress: data[:total_count] >= 20 ? [(data[:win_rate].to_f / 60 * 100).round(0), 100].min : [(data[:total_count].to_f / 20 * 50).round(0), 50].min,
      earned_date: nil
    }

    achievements << {
      id: "win_rate_70",
      name: "70% Win Rate",
      description: "Achieve a 70%+ win rate (min 50 trades)",
      icon: "star",
      category: "Performance",
      earned: data[:total_count] >= 50 && data[:win_rate] >= 70,
      progress: data[:total_count] >= 50 ? [(data[:win_rate].to_f / 70 * 100).round(0), 100].min : [(data[:total_count].to_f / 50 * 50).round(0), 50].min,
      earned_date: nil
    }

    # ── Risk Management ──────────────────────────────────────
    achievements << {
      id: "rr_2_for_10",
      name: "Risk/Reward Master",
      description: "Maintain 2:1+ R:R on 10 trades",
      icon: "balance",
      category: "Risk Management",
      earned: data[:trades_with_good_rr] >= 10,
      progress: [(data[:trades_with_good_rr].to_f / 10 * 100).round(0), 100].min,
      earned_date: nil
    }

    achievements << {
      id: "max_dd_5",
      name: "Capital Guardian",
      description: "Keep max drawdown under 5%",
      icon: "shield",
      category: "Risk Management",
      earned: data[:total_count] >= 20 && data[:max_drawdown] < 5,
      progress: data[:total_count] >= 20 ? (data[:max_drawdown] < 5 ? 100 : [(100 - data[:max_drawdown]).round(0).clamp(0, 99), 99].min) : [(data[:total_count].to_f / 20 * 50).round(0), 50].min,
      earned_date: nil
    }

    achievements << {
      id: "stops_10",
      name: "Disciplined Trader",
      description: "Use stop losses on 10 trades",
      icon: "security",
      category: "Risk Management",
      earned: data[:trades_with_stops] >= 10,
      progress: [(data[:trades_with_stops].to_f / 10 * 100).round(0), 100].min,
      earned_date: nil
    }

    # ── Psychology ───────────────────────────────────────────
    achievements << {
      id: "journal_7_days",
      name: "Journal Warrior",
      description: "Journal 7 days straight",
      icon: "auto_stories",
      category: "Psychology",
      earned: data[:journal_streak] >= 7,
      progress: [(data[:journal_streak].to_f / 7 * 100).round(0), 100].min,
      earned_date: nil
    }

    achievements << {
      id: "review_10",
      name: "Self-Aware Trader",
      description: "Review 10 trades",
      icon: "psychology",
      category: "Psychology",
      earned: data[:reviewed_trades] >= 10,
      progress: [(data[:reviewed_trades].to_f / 10 * 100).round(0), 100].min,
      earned_date: nil
    }

    achievements << {
      id: "all_journaled_week",
      name: "Perfect Week",
      description: "Journal every trading day this week",
      icon: "check_circle",
      category: "Psychology",
      earned: data[:all_journaled_this_week] && data[:trades].any?,
      progress: data[:all_journaled_this_week] ? 100 : (data[:journal_dates].any? ? 50 : 0),
      earned_date: data[:all_journaled_this_week] ? Date.today.to_s : nil
    }

    # ── Milestones ───────────────────────────────────────────
    achievements << {
      id: "profit_1k",
      name: "$1K Total Profit",
      description: "Earn $1,000 in cumulative profit",
      icon: "savings",
      category: "Milestones",
      earned: data[:total_pnl] >= 1_000,
      progress: data[:total_pnl] > 0 ? [(data[:total_pnl].to_f / 1_000 * 100).round(0), 100].min : 0,
      earned_date: data[:total_pnl] >= 1_000 ? cumulative_milestone_date(data[:trades], 1_000) : nil
    }

    achievements << {
      id: "profit_5k",
      name: "$5K Total Profit",
      description: "Earn $5,000 in cumulative profit",
      icon: "account_balance",
      category: "Milestones",
      earned: data[:total_pnl] >= 5_000,
      progress: data[:total_pnl] > 0 ? [(data[:total_pnl].to_f / 5_000 * 100).round(0), 100].min : 0,
      earned_date: data[:total_pnl] >= 5_000 ? cumulative_milestone_date(data[:trades], 5_000) : nil
    }

    achievements << {
      id: "profit_10k",
      name: "$10K Total Profit",
      description: "Earn $10,000 in cumulative profit",
      icon: "emoji_events",
      category: "Milestones",
      earned: data[:total_pnl] >= 10_000,
      progress: data[:total_pnl] > 0 ? [(data[:total_pnl].to_f / 10_000 * 100).round(0), 100].min : 0,
      earned_date: data[:total_pnl] >= 10_000 ? cumulative_milestone_date(data[:trades], 10_000) : nil
    }

    achievements << {
      id: "profit_50k",
      name: "$50K Total Profit",
      description: "Earn $50,000 in cumulative profit",
      icon: "workspace_premium",
      category: "Milestones",
      earned: data[:total_pnl] >= 50_000,
      progress: data[:total_pnl] > 0 ? [(data[:total_pnl].to_f / 50_000 * 100).round(0), 100].min : 0,
      earned_date: data[:total_pnl] >= 50_000 ? cumulative_milestone_date(data[:trades], 50_000) : nil
    }

    achievements
  end

  # ── Helper methods to estimate dates ──────────────────────

  def estimate_date(trades, index)
    return nil if trades.empty? || index >= trades.length
    trade = trades[index]
    (trade["exit_time"] || trade["entry_time"])&.to_s&.slice(0, 10)
  rescue
    nil
  end

  def first_win_date(trades)
    winner = trades.find { |t| t["pnl"].to_f > 0 }
    return nil unless winner
    (winner["exit_time"] || winner["entry_time"])&.to_s&.slice(0, 10)
  rescue
    nil
  end

  def estimate_review_date(trades)
    reviewed = trades.find { |t| t["reviewed"] || t["trade_grade"].present? }
    return nil unless reviewed
    (reviewed["exit_time"] || reviewed["entry_time"])&.to_s&.slice(0, 10)
  rescue
    nil
  end

  def first_day_above(daily_pnl, threshold)
    daily_pnl.sort_by { |d, _| d }.each do |date, pnl|
      return date if pnl >= threshold
    end
    nil
  rescue
    nil
  end

  def cumulative_milestone_date(trades, target)
    cumulative = 0
    trades.each do |t|
      cumulative += t["pnl"].to_f
      if cumulative >= target
        return (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 10)
      end
    end
    nil
  rescue
    nil
  end

  def active_days_progress(daily_pnl, target)
    count = daily_pnl.keys.count
    [(count.to_f / target * 100).round(0), 100].min
  rescue
    0
  end
end

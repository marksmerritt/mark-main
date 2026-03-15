class MilestonesController < ApplicationController
  before_action :require_api_connection

  def index
    threads = {}
    threads[:trades] = Thread.new { api_client.trades(per_page: 500, status: "closed") }
    threads[:overview] = Thread.new { api_client.overview }
    threads[:streaks] = Thread.new { api_client.streaks rescue {} }

    result = threads[:trades].value
    trades = result.is_a?(Hash) ? (result["trades"] || []) : (result || [])
    @overview = threads[:overview].value
    @overview = {} unless @overview.is_a?(Hash)
    @streaks = threads[:streaks].value
    @streaks = {} unless @streaks.is_a?(Hash)

    @total_trades = trades.count
    pnls = trades.map { |t| t["pnl"].to_f }
    @total_pnl = pnls.sum
    @win_rate = pnls.count { |p| p > 0 }.to_f / [pnls.count, 1].max * 100
    @best_trade = trades.max_by { |t| t["pnl"].to_f }
    @worst_trade = trades.min_by { |t| t["pnl"].to_f }

    # Cumulative P&L for milestone detection
    cumulative = 0
    @pnl_milestones_hit = []
    trades.sort_by { |t| t["entry_time"].to_s }.each do |t|
      cumulative += t["pnl"].to_f
      @pnl_milestones_hit << cumulative.round(2)
    end

    # Longest winning streak
    max_win_streak = 0; current = 0
    trades.each { |t| t["pnl"].to_f > 0 ? (current += 1; max_win_streak = [max_win_streak, current].max) : current = 0 }
    @max_win_streak = max_win_streak

    # Unique symbols traded
    @symbols_traded = trades.map { |t| t["symbol"] }.compact.uniq.count

    # Green days
    daily_pnl = @overview["daily_pnl"] || {}
    @green_days = daily_pnl.values.count { |v| v.to_f > 0 }
    @total_days = daily_pnl.count

    # Days with journal
    @reviewed_trades = trades.count { |t| t["reviewed"] || t["trade_grade"].present? }

    # Define milestones
    @milestones = build_milestones(trades)

    # Summary stats
    @unlocked = @milestones.count { |m| m[:unlocked] }
    @total_milestones = @milestones.count
    @progress = (@unlocked.to_f / @total_milestones * 100).round(0)

    # Group by category
    @by_category = @milestones.group_by { |m| m[:category] }
  end

  private

  def build_milestones(trades)
    pnls = trades.map { |t| t["pnl"].to_f }
    total_pnl = pnls.sum
    total = trades.count
    win_rate = total > 0 ? (pnls.count { |p| p > 0 }.to_f / total * 100) : 0
    best = pnls.max || 0
    reviewed = trades.count { |t| t["reviewed"] || t["trade_grade"].present? }

    [
      # Volume milestones
      { category: "Volume", icon: "bar_chart", name: "First Trade", description: "Log your first trade", threshold: 1, current: total, unlocked: total >= 1 },
      { category: "Volume", icon: "bar_chart", name: "Getting Started", description: "Complete 10 trades", threshold: 10, current: total, unlocked: total >= 10 },
      { category: "Volume", icon: "bar_chart", name: "Active Trader", description: "Complete 50 trades", threshold: 50, current: total, unlocked: total >= 50 },
      { category: "Volume", icon: "bar_chart", name: "Experienced", description: "Complete 100 trades", threshold: 100, current: total, unlocked: total >= 100 },
      { category: "Volume", icon: "bar_chart", name: "Veteran", description: "Complete 250 trades", threshold: 250, current: total, unlocked: total >= 250 },
      { category: "Volume", icon: "bar_chart", name: "Master Trader", description: "Complete 500 trades", threshold: 500, current: total, unlocked: total >= 500 },

      # P&L milestones
      { category: "Profit", icon: "payments", name: "First Green", description: "Earn $100 cumulative P&L", threshold: 100, current: total_pnl, unlocked: total_pnl >= 100, format: :currency },
      { category: "Profit", icon: "payments", name: "Four Figures", description: "Earn $1,000 cumulative P&L", threshold: 1000, current: total_pnl, unlocked: total_pnl >= 1000, format: :currency },
      { category: "Profit", icon: "payments", name: "Serious Money", description: "Earn $5,000 cumulative P&L", threshold: 5000, current: total_pnl, unlocked: total_pnl >= 5000, format: :currency },
      { category: "Profit", icon: "payments", name: "Five Figures", description: "Earn $10,000 cumulative P&L", threshold: 10000, current: total_pnl, unlocked: total_pnl >= 10000, format: :currency },

      # Win rate milestones
      { category: "Performance", icon: "emoji_events", name: "Coin Flip", description: "Achieve 50% win rate (20+ trades)", threshold: 50, current: win_rate.round(1), unlocked: total >= 20 && win_rate >= 50, format: :pct },
      { category: "Performance", icon: "emoji_events", name: "Edge", description: "Achieve 55% win rate (50+ trades)", threshold: 55, current: win_rate.round(1), unlocked: total >= 50 && win_rate >= 55, format: :pct },
      { category: "Performance", icon: "emoji_events", name: "Sharp Shooter", description: "Achieve 60% win rate (50+ trades)", threshold: 60, current: win_rate.round(1), unlocked: total >= 50 && win_rate >= 60, format: :pct },
      { category: "Performance", icon: "emoji_events", name: "Elite", description: "Achieve 70% win rate (50+ trades)", threshold: 70, current: win_rate.round(1), unlocked: total >= 50 && win_rate >= 70, format: :pct },

      # Streak milestones
      { category: "Streaks", icon: "local_fire_department", name: "Hot Hand", description: "Win 3 trades in a row", threshold: 3, current: @max_win_streak, unlocked: @max_win_streak >= 3 },
      { category: "Streaks", icon: "local_fire_department", name: "On Fire", description: "Win 5 trades in a row", threshold: 5, current: @max_win_streak, unlocked: @max_win_streak >= 5 },
      { category: "Streaks", icon: "local_fire_department", name: "Unstoppable", description: "Win 10 trades in a row", threshold: 10, current: @max_win_streak, unlocked: @max_win_streak >= 10 },
      { category: "Streaks", icon: "local_fire_department", name: "Green Week", description: "5 profitable trading days", threshold: 5, current: @green_days, unlocked: @green_days >= 5 },
      { category: "Streaks", icon: "local_fire_department", name: "Green Month", description: "20 profitable trading days", threshold: 20, current: @green_days, unlocked: @green_days >= 20 },

      # Diversity milestones
      { category: "Diversity", icon: "donut_small", name: "Explorer", description: "Trade 3 different symbols", threshold: 3, current: @symbols_traded, unlocked: @symbols_traded >= 3 },
      { category: "Diversity", icon: "donut_small", name: "Diversified", description: "Trade 10 different symbols", threshold: 10, current: @symbols_traded, unlocked: @symbols_traded >= 10 },
      { category: "Diversity", icon: "donut_small", name: "Market Expert", description: "Trade 25 different symbols", threshold: 25, current: @symbols_traded, unlocked: @symbols_traded >= 25 },

      # Discipline milestones
      { category: "Discipline", icon: "school", name: "Self-Aware", description: "Review 10 trades", threshold: 10, current: reviewed, unlocked: reviewed >= 10 },
      { category: "Discipline", icon: "school", name: "Studious", description: "Review 50 trades", threshold: 50, current: reviewed, unlocked: reviewed >= 50 },
      { category: "Discipline", icon: "school", name: "Scholar", description: "Review 100 trades", threshold: 100, current: reviewed, unlocked: reviewed >= 100 },

      # Big trade milestones
      { category: "Big Moves", icon: "rocket_launch", name: "Nice Win", description: "Single trade profit of $500+", threshold: 500, current: best, unlocked: best >= 500, format: :currency },
      { category: "Big Moves", icon: "rocket_launch", name: "Home Run", description: "Single trade profit of $1,000+", threshold: 1000, current: best, unlocked: best >= 1000, format: :currency },
      { category: "Big Moves", icon: "rocket_launch", name: "Grand Slam", description: "Single trade profit of $5,000+", threshold: 5000, current: best, unlocked: best >= 5000, format: :currency },
    ]
  end
end

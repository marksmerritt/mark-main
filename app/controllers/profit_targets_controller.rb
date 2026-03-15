class ProfitTargetsController < ApplicationController
  include ActionView::Helpers::NumberHelper

  before_action :require_api_connection

  def show
    stats_thread = Thread.new do
      resp = api_client.overview
      resp.is_a?(Hash) ? resp : {}
    rescue => e
      Rails.logger.error("profit_targets stats: #{e.message}")
      {}
    end

    stats = stats_thread.value

    # Extract daily_pnl - can be Array of pairs or Hash
    raw_daily_pnl = stats["daily_pnl"] || {}
    @daily_pnl = raw_daily_pnl.is_a?(Array) ? raw_daily_pnl.to_h : raw_daily_pnl

    # Convert all values to floats
    @daily_pnl_floats = @daily_pnl.transform_values(&:to_f)

    today_str = Date.current.to_s
    week_start = Date.current.beginning_of_week(:monday)
    month_start = Date.current.beginning_of_month

    # Today's P&L
    @today_pnl = @daily_pnl_floats[today_str] || 0.0

    # This week's cumulative P&L
    @week_pnl = @daily_pnl_floats.select { |d, _| Date.parse(d) >= week_start rescue false }.values.sum

    # This month's cumulative P&L
    @month_pnl = @daily_pnl_floats.select { |d, _| Date.parse(d) >= month_start rescue false }.values.sum

    # All-time stats
    all_values = @daily_pnl_floats.values
    @total_trading_days = all_values.count
    @avg_daily_pnl = @total_trading_days > 0 ? (all_values.sum / @total_trading_days).round(2) : 0.0

    # Suggested targets based on average
    @suggested_daily = @avg_daily_pnl > 0 ? (@avg_daily_pnl * 0.8).round(0) : 500.0
    @suggested_weekly = (@suggested_daily * 5).round(0)
    @suggested_monthly = (@suggested_daily * 22).round(0)

    # Best and worst days
    if @daily_pnl_floats.any?
      best_entry = @daily_pnl_floats.max_by { |_, v| v }
      worst_entry = @daily_pnl_floats.min_by { |_, v| v }
      @best_day = { date: best_entry[0], pnl: best_entry[1] }
      @worst_day = { date: worst_entry[0], pnl: worst_entry[1] }
    else
      @best_day = { date: "N/A", pnl: 0.0 }
      @worst_day = { date: "N/A", pnl: 0.0 }
    end

    # Last 30 days for chart
    sorted_entries = @daily_pnl_floats.sort_by { |d, _| d }
    @chart_data = sorted_entries.last(30)

    # Target hit rate (will use suggested_daily as default; JS overrides with localStorage)
    @default_daily_target = @suggested_daily
    compute_target_stats(@default_daily_target)

    # Streaks
    compute_streaks(@default_daily_target)

    # Motivational message
    @motivation = compute_motivation

    # Overall stats
    @win_rate = stats["win_rate"].to_f.round(1)
    @total_pnl = stats["total_pnl"].to_f
    @total_trades = stats["total_trades"].to_i
  end

  private

  def compute_target_stats(daily_target)
    return @target_hit_days = 0, @target_hit_rate = 0.0 if @daily_pnl_floats.empty?

    @target_hit_days = @daily_pnl_floats.values.count { |v| v >= daily_target }
    @target_hit_rate = @total_trading_days > 0 ? (@target_hit_days.to_f / @total_trading_days * 100).round(1) : 0.0
    @target_miss_days = @total_trading_days - @target_hit_days
  end

  def compute_streaks(daily_target)
    sorted = @daily_pnl_floats.sort_by { |d, _| d }

    @current_streak = 0
    @best_streak = 0
    current = 0

    sorted.each do |_, pnl|
      if pnl >= daily_target
        current += 1
        @best_streak = current if current > @best_streak
      else
        current = 0
      end
    end
    @current_streak = current

    # Also compute losing streak
    @worst_streak = 0
    current_loss = 0
    sorted.each do |_, pnl|
      if pnl < daily_target
        current_loss += 1
        @worst_streak = current_loss if current_loss > @worst_streak
      else
        current_loss = 0
      end
    end
  end

  def compute_motivation
    if @today_pnl >= @default_daily_target && @default_daily_target > 0
      { icon: "celebration", color: "#4caf50", message: "Target hit today! Great discipline. Consider locking in profits." }
    elsif @today_pnl > 0
      pct = @default_daily_target > 0 ? (@today_pnl / @default_daily_target * 100).round(0) : 0
      { icon: "trending_up", color: "#2196f3", message: "#{pct}% of daily target reached. Stay focused on quality setups." }
    elsif @today_pnl == 0
      { icon: "wb_sunny", color: "#ff9800", message: "New day, fresh start. Focus on process, not outcome." }
    elsif @today_pnl > -@default_daily_target
      { icon: "psychology", color: "#ff9800", message: "Small setback. Stick to your plan and avoid revenge trading." }
    else
      { icon: "self_improvement", color: "#f44336", message: "Tough day. Consider stepping away. Protecting capital is priority #1." }
    end
  end
end

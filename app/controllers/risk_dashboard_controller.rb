class RiskDashboardController < ApplicationController
  before_action :require_api_connection

  include ActionView::Helpers::NumberHelper

  def index
    threads = {}
    threads[:open] = Thread.new {
      result = api_client.trades(status: "open", per_page: 200)
      result.is_a?(Hash) ? (result["trades"] || []) : Array(result)
    }
    threads[:recent] = Thread.new {
      result = api_client.trades(
        status: "closed",
        start_date: 30.days.ago.to_date.to_s,
        end_date: Date.current.to_s,
        per_page: 200
      )
      result.is_a?(Hash) ? (result["trades"] || []) : Array(result)
    }
    threads[:all_closed] = Thread.new {
      result = api_client.trades(status: "closed", per_page: 500)
      result.is_a?(Hash) ? (result["trades"] || []) : Array(result)
    }
    threads[:overview] = Thread.new { api_client.overview rescue {} }
    threads[:streaks] = Thread.new { api_client.streaks rescue {} }

    @open_trades = threads[:open].value
    @recent_trades = threads[:recent].value
    @all_trades = threads[:all_closed].value
    @overview = threads[:overview].value || {}
    @streaks = threads[:streaks].value || {}

    compute_risk_metrics
    compute_position_health
    compute_drawdown_analysis
    compute_risk_limits
    compute_alerts
  end

  private

  def compute_risk_metrics
    # Current open risk
    @total_risk_at_stop = 0
    @positions_without_stops = 0
    @open_trades.each do |t|
      stop = t["stop_loss"]&.to_f
      entry = t["entry_price"].to_f
      qty = t["quantity"].to_i
      if stop && stop > 0 && entry > 0 && qty > 0
        @total_risk_at_stop += (entry - stop).abs * qty
      else
        @positions_without_stops += 1
      end
    end

    # Unrealized P&L
    @unrealized_pnl = @open_trades.sum { |t| t["pnl"].to_f }

    # Recent performance metrics (30 days)
    @recent_pnl = @recent_trades.sum { |t| t["pnl"].to_f }
    @recent_wins = @recent_trades.count { |t| t["pnl"].to_f > 0 }
    @recent_losses = @recent_trades.count { |t| t["pnl"].to_f < 0 }
    @recent_win_rate = @recent_trades.any? ? (@recent_wins.to_f / @recent_trades.count * 100).round(1) : 0
    @recent_avg_win = @recent_wins > 0 ? @recent_trades.select { |t| t["pnl"].to_f > 0 }.sum { |t| t["pnl"].to_f } / @recent_wins : 0
    @recent_avg_loss = @recent_losses > 0 ? @recent_trades.select { |t| t["pnl"].to_f < 0 }.sum { |t| t["pnl"].to_f } / @recent_losses : 0

    # Expectancy
    @expectancy = if @recent_trades.any?
      (@recent_win_rate / 100.0 * @recent_avg_win + (1 - @recent_win_rate / 100.0) * @recent_avg_loss).round(2)
    else
      0
    end

    # Current streak
    cs = @streaks.is_a?(Hash) ? @streaks["current_streak"] : nil
    @current_streak = cs.is_a?(Hash) ? cs["count"].to_i : cs.to_i
    @streak_type = cs.is_a?(Hash) ? cs["type"] : (@streaks.is_a?(Hash) ? @streaks["streak_type"] : nil)
  end

  def compute_position_health
    @position_health = @open_trades.map { |t|
      entry = t["entry_price"].to_f
      stop = t["stop_loss"]&.to_f
      target = t["take_profit"]&.to_f
      pnl = t["pnl"].to_f
      qty = t["quantity"].to_i

      risk = stop && stop > 0 ? (entry - stop).abs * qty : nil
      reward = target && target > 0 ? (target - entry).abs * qty : nil
      rr_ratio = risk && risk > 0 && reward ? (reward / risk).round(2) : nil

      # Health score (0-100)
      health = 50
      health += 15 if stop && stop > 0  # Has stop loss
      health += 15 if target && target > 0  # Has take profit
      health += 10 if rr_ratio && rr_ratio >= 2  # Good R:R
      health -= 20 if pnl < 0 && risk && pnl.abs > risk  # Beyond stop
      health += 10 if pnl > 0  # In profit

      {
        id: t["id"],
        symbol: t["symbol"],
        side: t["side"],
        entry: entry,
        pnl: pnl,
        stop: stop,
        target: target,
        risk: risk,
        reward: reward,
        rr_ratio: rr_ratio,
        health: health.clamp(0, 100),
        has_stop: stop && stop > 0,
        has_target: target && target > 0,
        r_multiple: risk && risk > 0 ? (pnl / risk).round(2) : nil
      }
    }.sort_by { |p| p[:health] }
  end

  def compute_drawdown_analysis
    # Build equity curve from all trades
    running = 0
    peak = 0
    @drawdown_curve = []
    sorted = @all_trades.sort_by { |t| t["exit_time"] || t["entry_time"] || "" }

    sorted.each do |t|
      running += t["pnl"].to_f
      peak = [peak, running].max
      dd = peak > 0 ? ((peak - running) / peak * 100).round(2) : 0
      @drawdown_curve << {
        date: (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 10),
        equity: running.round(2),
        peak: peak.round(2),
        drawdown_pct: dd
      }
    end

    @max_drawdown = @drawdown_curve.map { |d| d[:drawdown_pct] }.max || 0
    @current_drawdown = @drawdown_curve.last&.dig(:drawdown_pct) || 0
    @equity_peak = @drawdown_curve.map { |d| d[:peak] }.max || 0
    @current_equity = @drawdown_curve.last&.dig(:equity) || 0

    # Recovery needed
    @recovery_needed = @current_drawdown > 0 ? ((@equity_peak - @current_equity) / [@current_equity, 1].max * 100).round(1) : 0

    # Drawdown duration (how many trades since peak)
    peak_idx = @drawdown_curve.rindex { |d| d[:equity] == d[:peak] } || 0
    @drawdown_duration = @drawdown_curve.count - peak_idx - 1
  end

  def compute_risk_limits
    # Dynamic risk limits based on recent performance
    @daily_pnl_today = @recent_trades.select { |t|
      date = (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 10)
      date == Date.current.to_s
    }.sum { |t| t["pnl"].to_f }

    # Suggested daily loss limit (2% of peak equity or $500, whichever is larger)
    @daily_loss_limit = [(@equity_peak * 0.02).round(2), 500].max
    @daily_limit_used = @daily_pnl_today < 0 ? (@daily_pnl_today.abs / @daily_loss_limit * 100).round(1) : 0

    # Weekly P&L
    week_start = Date.current.beginning_of_week(:monday)
    @weekly_pnl = @recent_trades.select { |t|
      date = (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 10)
      date && date >= week_start.to_s
    }.sum { |t| t["pnl"].to_f }

    @weekly_loss_limit = @daily_loss_limit * 3
    @weekly_limit_used = @weekly_pnl < 0 ? (@weekly_pnl.abs / @weekly_loss_limit * 100).round(1) : 0

    # Max consecutive losses
    consecutive_losses = 0
    max_consecutive = 0
    @recent_trades.sort_by { |t| t["exit_time"] || t["entry_time"] || "" }.each do |t|
      if t["pnl"].to_f < 0
        consecutive_losses += 1
        max_consecutive = [max_consecutive, consecutive_losses].max
      else
        consecutive_losses = 0
      end
    end
    @max_consecutive_losses = max_consecutive
  end

  def compute_alerts
    @alerts = []

    if @positions_without_stops > 0
      @alerts << { severity: "danger", icon: "warning", message: "#{@positions_without_stops} position#{'s' if @positions_without_stops != 1} without stop losses" }
    end

    if @current_drawdown > 10
      @alerts << { severity: "danger", icon: "trending_down", message: "Drawdown at #{@current_drawdown}% — consider reducing position sizes" }
    elsif @current_drawdown > 5
      @alerts << { severity: "warning", icon: "trending_down", message: "Drawdown at #{@current_drawdown}% — monitor closely" }
    end

    if @daily_limit_used > 80
      @alerts << { severity: "danger", icon: "block", message: "Daily loss limit #{@daily_limit_used.round}% used — consider stopping for the day" }
    elsif @daily_limit_used > 50
      @alerts << { severity: "warning", icon: "warning", message: "Daily loss limit #{@daily_limit_used.round}% used" }
    end

    if @max_consecutive_losses >= 3
      @alerts << { severity: "warning", icon: "psychology", message: "#{@max_consecutive_losses} consecutive losses recently — check for tilt" }
    end

    if @streak_type == "loss" && @current_streak.abs >= 3
      @alerts << { severity: "warning", icon: "local_fire_department", message: "On a #{@current_streak.abs}-trade losing streak" }
    end

    if @recent_win_rate < 40 && @recent_trades.count >= 5
      @alerts << { severity: "warning", icon: "analytics", message: "Win rate dropped to #{@recent_win_rate}% over last 30 days" }
    end

    if @expectancy < 0 && @recent_trades.count >= 10
      @alerts << { severity: "danger", icon: "functions", message: "Negative expectancy ($#{@expectancy}) — review your edge" }
    end

    # Positive alerts
    if @streak_type == "win" && @current_streak >= 5
      @alerts << { severity: "success", icon: "stars", message: "#{@current_streak}-trade winning streak!" }
    end

    if @current_drawdown == 0 && @current_equity > 0
      @alerts << { severity: "success", icon: "trending_up", message: "At all-time equity highs!" }
    end
  end
end

class AccountSummaryController < ApplicationController
  before_action :require_api_connection

  include ActionView::Helpers::NumberHelper

  def show
    trade_result = api_client.trades(per_page: 1000)
    all_trades = trade_result.is_a?(Hash) ? (trade_result["trades"] || []) : Array(trade_result)
    all_trades = all_trades.select { |t| t.is_a?(Hash) }
    @trades = all_trades.select { |t| t["status"]&.downcase == "closed" }

    return if @trades.empty?

    sorted_trades = @trades.sort_by { |t| t["exit_time"] || t["entry_time"] || "" }

    pnls = sorted_trades.map { |t| t["pnl"].to_f }
    wins = sorted_trades.select { |t| t["pnl"].to_f > 0 }
    losses = sorted_trades.select { |t| t["pnl"].to_f < 0 }

    # === Account Metrics ===
    @total_trades = sorted_trades.count
    @total_pnl = pnls.sum
    @win_rate = @total_trades > 0 ? (wins.count.to_f / @total_trades * 100).round(1) : 0
    gross_profit = wins.sum { |t| t["pnl"].to_f }
    gross_loss = losses.sum { |t| t["pnl"].to_f.abs }
    @profit_factor = gross_loss > 0 ? (gross_profit / gross_loss).round(2) : (gross_profit > 0 ? 99.0 : 0.0)
    @avg_win = wins.any? ? (gross_profit / wins.count).round(2) : 0
    @avg_loss = losses.any? ? (gross_loss / losses.count).round(2) : 0
    @expectancy = @total_trades > 0 ? (@total_pnl / @total_trades).round(2) : 0

    # === Equity Curve ===
    cumulative = 0
    @equity_curve = sorted_trades.map do |t|
      cumulative += t["pnl"].to_f
      cumulative.round(2)
    end

    # === Max Drawdown ===
    peak = 0
    @max_drawdown = 0
    @equity_curve.each do |val|
      peak = val if val > peak
      dd = peak - val
      @max_drawdown = dd if dd > @max_drawdown
    end

    # === Time-based P&L ===
    daily_pnl = {}
    sorted_trades.each do |t|
      date = (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 10)
      next unless date
      daily_pnl[date] ||= 0
      daily_pnl[date] += t["pnl"].to_f
    end

    weekly_pnl = {}
    daily_pnl.each do |date_str, pnl|
      begin
        d = Date.parse(date_str)
        week_key = "#{d.cwyear}-W#{d.cweek.to_s.rjust(2, '0')}"
        weekly_pnl[week_key] ||= 0
        weekly_pnl[week_key] += pnl
      rescue
        next
      end
    end

    monthly_pnl = {}
    daily_pnl.each do |date_str, pnl|
      month_key = date_str.slice(0, 7)
      monthly_pnl[month_key] ||= 0
      monthly_pnl[month_key] += pnl
    end

    quarterly_pnl = {}
    daily_pnl.each do |date_str, pnl|
      begin
        d = Date.parse(date_str)
        q = ((d.month - 1) / 3) + 1
        q_key = "#{d.year}-Q#{q}"
        quarterly_pnl[q_key] ||= 0
        quarterly_pnl[q_key] += pnl
      rescue
        next
      end
    end

    @daily_pnl = daily_pnl
    @weekly_pnl = weekly_pnl
    @monthly_pnl = monthly_pnl
    @quarterly_pnl = quarterly_pnl

    # === Best/Worst Periods ===
    @best_day = daily_pnl.any? ? daily_pnl.max_by { |_, v| v } : nil
    @worst_day = daily_pnl.any? ? daily_pnl.min_by { |_, v| v } : nil
    @best_week = weekly_pnl.any? ? weekly_pnl.max_by { |_, v| v } : nil
    @worst_week = weekly_pnl.any? ? weekly_pnl.min_by { |_, v| v } : nil
    @best_month = monthly_pnl.any? ? monthly_pnl.max_by { |_, v| v } : nil
    @worst_month = monthly_pnl.any? ? monthly_pnl.min_by { |_, v| v } : nil

    # === Rolling Performance ===
    sorted_dates = daily_pnl.keys.sort
    @rolling_7d = compute_rolling(daily_pnl, sorted_dates, 7)
    @rolling_30d = compute_rolling(daily_pnl, sorted_dates, 30)
    @rolling_90d = compute_rolling(daily_pnl, sorted_dates, 90)

    # Rolling win rates
    @rolling_7d_wr = compute_rolling_win_rate(sorted_trades, 7)
    @rolling_30d_wr = compute_rolling_win_rate(sorted_trades, 30)
    @rolling_90d_wr = compute_rolling_win_rate(sorted_trades, 90)

    # === Recovery Analysis ===
    @recovery_periods = compute_recovery_periods(@equity_curve)
    @avg_recovery_time = if @recovery_periods.any?
      (@recovery_periods.sum { |r| r[:duration] } / @recovery_periods.count.to_f).round(1)
    else
      0
    end
    @longest_drawdown = @recovery_periods.any? ? @recovery_periods.max_by { |r| r[:duration] }[:duration] : 0

    # === Sharpe-like Ratio ===
    daily_values = daily_pnl.values
    avg_daily_pnl = daily_values.any? ? daily_values.sum / daily_values.count : 0
    std_daily_pnl = if daily_values.count > 1
      variance = daily_values.sum { |d| (d - avg_daily_pnl) ** 2 } / (daily_values.count - 1)
      Math.sqrt(variance)
    else
      0
    end
    @sharpe_ratio = std_daily_pnl > 0 ? (avg_daily_pnl / std_daily_pnl).round(2) : 0

    # === Calmar-like Ratio ===
    @calmar_ratio = @max_drawdown > 0 ? (@total_pnl / @max_drawdown).round(2) : 0

    # === Trade Quality Score ===
    wr_score = [@win_rate / 100.0, 1.0].min * 30
    pf_score = [@profit_factor / 3.0, 1.0].min * 30

    profitable_months = monthly_pnl.values.count { |v| v > 0 }
    total_months = [monthly_pnl.count, 1].max
    consistency = (profitable_months.to_f / total_months)
    cons_score = consistency * 20

    sharpe_score = [(@sharpe_ratio.abs > 0 ? [@sharpe_ratio / 2.0, 1.0].min : 0), 0].max * 20

    @trade_quality_raw = (wr_score + pf_score + cons_score + sharpe_score).round(1)
    @trade_quality_grade = score_to_grade(@trade_quality_raw)

    # === Monthly Returns Grid (year x month matrix) ===
    @monthly_grid = {}
    monthly_pnl.each do |key, pnl|
      parts = key.split("-")
      next unless parts.length == 2
      year = parts[0].to_i
      month = parts[1].to_i
      @monthly_grid[year] ||= {}
      @monthly_grid[year][month] = pnl.round(2)
    end
  end

  private

  def compute_rolling(daily_pnl, sorted_dates, days)
    return 0 unless sorted_dates.any?
    begin
      cutoff = Date.parse(sorted_dates.last) - days
      recent = daily_pnl.select { |d, _| Date.parse(d) > cutoff }
      recent.values.sum.round(2)
    rescue
      0
    end
  end

  def compute_rolling_win_rate(trades, days)
    return 0 unless trades.any?
    begin
      latest = trades.filter_map { |t| t["exit_time"] || t["entry_time"] }.compact.sort.last
      return 0 unless latest
      cutoff = Date.parse(latest.to_s.slice(0, 10)) - days
      recent = trades.select do |t|
        d = (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 10)
        d && Date.parse(d) > cutoff
      end
      return 0 if recent.empty?
      wins = recent.count { |t| t["pnl"].to_f > 0 }
      (wins.to_f / recent.count * 100).round(1)
    rescue
      0
    end
  end

  def compute_recovery_periods(equity_curve)
    periods = []
    peak = 0
    drawdown_start = nil
    equity_curve.each_with_index do |val, i|
      if val > peak
        if drawdown_start && peak > 0
          periods << { start: drawdown_start, end: i, duration: i - drawdown_start }
        end
        peak = val
        drawdown_start = nil
      elsif val < peak && drawdown_start.nil?
        drawdown_start = i
      end
    end
    # If still in drawdown at end
    if drawdown_start
      periods << { start: drawdown_start, end: equity_curve.length - 1, duration: equity_curve.length - 1 - drawdown_start, recovered: false }
    end
    periods
  end

  def score_to_grade(score)
    case score
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
end

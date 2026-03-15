class PerformanceBenchmarksController < ApplicationController
  before_action :require_api_connection

  include ActionView::Helpers::NumberHelper

  def show
    threads = {}
    threads[:stats] = Thread.new { api_client.overview rescue {} }
    threads[:trades] = Thread.new { api_client.trades(per_page: 500) rescue {} }
    threads[:equity] = Thread.new { api_client.equity_curve rescue {} }
    threads[:streaks] = Thread.new { api_client.streaks rescue {} }

    @stats = threads[:stats].value || {}
    @stats = {} unless @stats.is_a?(Hash)

    trades_result = threads[:trades].value
    @trades = trades_result.is_a?(Hash) ? (trades_result["trades"] || []) : Array(trades_result)
    @trades = @trades.select { |t| t.is_a?(Hash) && t["status"] == "closed" }

    equity_result = threads[:equity].value
    @equity_curve = equity_result.is_a?(Hash) ? (equity_result["equity_curve"] || []) : (equity_result.is_a?(Array) ? equity_result : [])
    @equity_curve = @equity_curve.is_a?(Array) ? @equity_curve : []

    @streaks = threads[:streaks].value || {}
    @streaks = {} unless @streaks.is_a?(Hash)

    compute_benchmarks
    compute_monthly_comparison
    compute_risk_metrics
    compute_percentile_ranks
  end

  private

  def compute_benchmarks
    total_pnl = @trades.sum { |t| t["pnl"].to_f }
    wins = @trades.count { |t| t["pnl"].to_f > 0 }
    losses = @trades.count { |t| t["pnl"].to_f < 0 }
    win_rate = @trades.any? ? (wins.to_f / @trades.count * 100).round(1) : 0

    avg_win = wins > 0 ? @trades.select { |t| t["pnl"].to_f > 0 }.sum { |t| t["pnl"].to_f } / wins : 0
    avg_loss = losses > 0 ? @trades.select { |t| t["pnl"].to_f < 0 }.sum { |t| t["pnl"].to_f } / losses : 0
    profit_factor = avg_loss != 0 ? (avg_win * wins / (avg_loss.abs * losses)).round(2) : 0

    @your_metrics = {
      total_pnl: total_pnl,
      trade_count: @trades.count,
      win_rate: win_rate,
      avg_win: avg_win.round(2),
      avg_loss: avg_loss.round(2),
      profit_factor: profit_factor,
      largest_win: @trades.map { |t| t["pnl"].to_f }.max || 0,
      largest_loss: @trades.map { |t| t["pnl"].to_f }.min || 0,
      expectancy: @trades.any? ? (total_pnl / @trades.count).round(2) : 0
    }

    # Industry benchmarks (based on widely cited retail trader statistics)
    @benchmarks = {
      beginner: { win_rate: 35, profit_factor: 0.8, expectancy: -15, label: "Beginner", color: "#e53935" },
      average: { win_rate: 45, profit_factor: 1.0, expectancy: 0, label: "Average Retail", color: "#fb8c00" },
      competent: { win_rate: 50, profit_factor: 1.3, expectancy: 25, label: "Competent", color: "#fdd835" },
      skilled: { win_rate: 55, profit_factor: 1.8, expectancy: 50, label: "Skilled", color: "#43a047" },
      professional: { win_rate: 60, profit_factor: 2.5, expectancy: 100, label: "Professional", color: "#1e88e5" },
      elite: { win_rate: 65, profit_factor: 3.5, expectancy: 200, label: "Elite", color: "#8e24aa" }
    }

    # Determine user's tier
    score = 0
    score += 1 if win_rate >= 45
    score += 1 if win_rate >= 50
    score += 1 if win_rate >= 55
    score += 1 if win_rate >= 60
    score += 1 if profit_factor >= 1.3
    score += 1 if profit_factor >= 2.0
    score += 1 if @your_metrics[:expectancy] > 0
    score += 1 if @your_metrics[:expectancy] > 50

    @tier = case score
            when 0..1 then :beginner
            when 2..3 then :average
            when 4 then :competent
            when 5..6 then :skilled
            when 7 then :professional
            else :elite
            end

    @tier_info = @benchmarks[@tier]
  end

  def compute_monthly_comparison
    @monthly_data = {}
    @trades.each do |t|
      date = (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 7)
      next unless date
      @monthly_data[date] ||= { pnl: 0, trades: 0, wins: 0 }
      @monthly_data[date][:pnl] += t["pnl"].to_f
      @monthly_data[date][:trades] += 1
      @monthly_data[date][:wins] += 1 if t["pnl"].to_f > 0
    end
    @monthly_data = @monthly_data.sort_by { |k, _| k }.last(12).to_h

    # Calculate month-over-month improvement
    months = @monthly_data.values
    @improving = if months.size >= 2
      recent_half = months.last(months.size / 2)
      earlier_half = months.first(months.size / 2)
      recent_avg = recent_half.sum { |m| m[:pnl] } / recent_half.size
      earlier_avg = earlier_half.sum { |m| m[:pnl] } / earlier_half.size
      recent_avg > earlier_avg
    else
      nil
    end

    # Consistency score: what % of months were profitable?
    profitable_months = @monthly_data.values.count { |m| m[:pnl] > 0 }
    @consistency_pct = @monthly_data.any? ? (profitable_months.to_f / @monthly_data.size * 100).round(0) : 0
  end

  def compute_risk_metrics
    pnls = @trades.map { |t| t["pnl"].to_f }
    return if pnls.empty?

    # Max drawdown from equity curve
    running = 0
    peak = 0
    max_dd = 0
    pnls.each do |p|
      running += p
      peak = running if running > peak
      dd = peak - running
      max_dd = dd if dd > max_dd
    end
    @max_drawdown = max_dd

    # Sharpe-like ratio (simplified)
    mean = pnls.sum / pnls.size.to_f
    variance = pnls.sum { |p| (p - mean) ** 2 } / pnls.size.to_f
    std_dev = Math.sqrt(variance)
    @sharpe_ratio = std_dev > 0 ? (mean / std_dev).round(2) : 0

    # Sortino ratio (downside deviation only)
    neg_pnls = pnls.select { |p| p < 0 }
    if neg_pnls.any?
      down_var = neg_pnls.sum { |p| p ** 2 } / neg_pnls.size.to_f
      down_dev = Math.sqrt(down_var)
      @sortino_ratio = down_dev > 0 ? (mean / down_dev).round(2) : 0
    else
      @sortino_ratio = mean > 0 ? 99.0 : 0
    end

    # Calmar ratio (annualized return / max drawdown)
    total_days = if @trades.size >= 2
      first_date = Date.parse(@trades.last["entry_time"] || "") rescue Date.today
      last_date = Date.parse(@trades.first["exit_time"] || @trades.first["entry_time"] || "") rescue Date.today
      (last_date - first_date).to_i.abs
    else
      252
    end
    total_days = 1 if total_days == 0
    annualized_return = pnls.sum / total_days * 252
    @calmar_ratio = max_dd > 0 ? (annualized_return / max_dd).round(2) : 0

    # Risk benchmarks
    @risk_benchmarks = [
      { label: "Sharpe Ratio", yours: @sharpe_ratio, good: 0.5, great: 1.0, elite: 2.0 },
      { label: "Sortino Ratio", yours: @sortino_ratio, good: 1.0, great: 2.0, elite: 3.0 },
      { label: "Calmar Ratio", yours: @calmar_ratio, good: 1.0, great: 2.0, elite: 3.0 },
      { label: "Consistency", yours: @consistency_pct, good: 50, great: 65, elite: 80, suffix: "%" },
      { label: "Max Drawdown", yours: @max_drawdown.round(0), good: 5000, great: 2000, elite: 1000, inverse: true, prefix: "$" }
    ]
  end

  def compute_percentile_ranks
    # Simulated percentile ranks based on industry data
    @percentiles = {}
    wr = @your_metrics[:win_rate]
    @percentiles[:win_rate] = case wr
                              when 0..30 then 10
                              when 30..40 then 25
                              when 40..45 then 40
                              when 45..50 then 55
                              when 50..55 then 70
                              when 55..60 then 85
                              when 60..65 then 92
                              else 98
                              end

    pf = @your_metrics[:profit_factor]
    @percentiles[:profit_factor] = case pf
                                   when -Float::INFINITY..0.5 then 10
                                   when 0.5..1.0 then 30
                                   when 1.0..1.5 then 50
                                   when 1.5..2.0 then 70
                                   when 2.0..3.0 then 85
                                   when 3.0..5.0 then 95
                                   else 99
                                   end

    exp = @your_metrics[:expectancy]
    @percentiles[:expectancy] = case exp
                                when -Float::INFINITY..0 then 30
                                when 0..25 then 50
                                when 25..50 then 65
                                when 50..100 then 80
                                when 100..200 then 90
                                else 97
                                end

    @overall_percentile = ((@percentiles[:win_rate] + @percentiles[:profit_factor] + @percentiles[:expectancy]) / 3.0).round(0)
  end
end

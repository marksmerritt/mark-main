class DrawdownTrackerController < ApplicationController
  include ApiConnected

  def show
    stats_thread = Thread.new do
      api_client.overview
    rescue => e
      Rails.logger.error("drawdown_tracker overview: #{e.message}")
      {}
    end

    equity_thread = Thread.new do
      api_client.equity_curve
    rescue => e
      Rails.logger.error("drawdown_tracker equity: #{e.message}")
      {}
    end

    risk_thread = Thread.new do
      api_client.risk_analysis
    rescue => e
      Rails.logger.error("drawdown_tracker risk: #{e.message}")
      {}
    end

    trades_thread = Thread.new do
      api_client.trades(per_page: 500, sort: "closed_at", direction: "asc")
    rescue => e
      Rails.logger.error("drawdown_tracker trades: #{e.message}")
      {}
    end

    stats = stats_thread.value || {}
    equity_data = equity_thread.value || {}
    risk = risk_thread.value || {}
    raw_trades = trades_thread.value || {}

    trades = extract_trades(raw_trades)
    daily_pnl = normalize_daily_pnl(stats)
    equity_points = extract_equity(equity_data)

    @current_drawdown = compute_current_drawdown(equity_points)
    @max_drawdown = compute_max_drawdown(equity_points)
    @drawdown_history = compute_drawdown_periods(equity_points)
    @recovery_info = compute_recovery_info(equity_points)
    @monthly_drawdowns = compute_monthly_drawdowns(daily_pnl)
    @drawdown_chart = build_drawdown_chart(equity_points)
    @risk_metrics = extract_risk_metrics(risk, stats)
    @worst_days = worst_trading_days(daily_pnl, 5)
    @drawdown_rules = generate_rules(@risk_metrics)
  end

  private

  def extract_trades(raw)
    return raw if raw.is_a?(Array)
    raw.is_a?(Hash) ? (raw["trades"] || raw["data"] || []) : []
  end

  def normalize_daily_pnl(stats)
    raw = stats.is_a?(Hash) ? (stats["daily_pnl"] || {}) : {}
    pnl = raw.is_a?(Array) ? raw.to_h : raw
    pnl.transform_keys(&:to_s).transform_values { |v| v.to_f }
  end

  def extract_equity(data)
    # API can return:
    # 1. Array of hashes: [{"date" => "2025-09-15", "pnl" => -7.1, "cumulative" => -7.1}, ...]
    # 2. Hash with key: {"equity_curve" => [...], ...}
    # 3. Hash of date => value
    points = if data.is_a?(Array)
               data
             elsif data.is_a?(Hash)
               data["equity_curve"] || data["points"] || data["data"] || []
             else
               []
             end

    # If points is still a hash (date => value map), convert it
    if points.is_a?(Hash)
      return points.reject { |k, _| %w[error message].include?(k) }
                   .map { |date, val| { "date" => date.to_s, "equity" => val.to_f } }
                   .sort_by { |p| p["date"] }
    end

    Array(points).map do |p|
      if p.is_a?(Hash)
        eq = (p["equity"] || p["cumulative"] || p["cumulative_pnl"] || p["value"] || 0).to_f
        { "date" => (p["date"] || p["closed_at"] || "").to_s, "equity" => eq }
      elsif p.is_a?(Array)
        { "date" => p[0].to_s, "equity" => p[1].to_f }
      else
        nil
      end
    end.compact
  end

  def compute_current_drawdown(equity_points)
    return { pct: 0, amount: 0, peak: 0, current: 0, days: 0 } if equity_points.empty?

    peak = equity_points.map { |p| p["equity"] }.max
    current = equity_points.last["equity"]
    dd_amount = peak - current
    dd_pct = peak > 0 ? (dd_amount / peak * 100) : 0

    # Days since peak
    peak_idx = equity_points.rindex { |p| p["equity"] == peak }
    days_since = peak_idx ? equity_points.length - 1 - peak_idx : 0

    { pct: dd_pct.round(2), amount: dd_amount.round(2), peak: peak.round(2), current: current.round(2), days: days_since }
  end

  def compute_max_drawdown(equity_points)
    return { pct: 0, amount: 0, start_date: nil, end_date: nil, recovery_date: nil } if equity_points.empty?

    peak = 0
    max_dd = 0
    max_dd_peak = 0
    max_dd_trough = 0
    dd_start = nil
    dd_end = nil
    current_dd_start = nil

    equity_points.each do |p|
      eq = p["equity"]
      if eq > peak
        peak = eq
        current_dd_start = p["date"]
      end
      dd = peak - eq
      if dd > max_dd
        max_dd = dd
        max_dd_peak = peak
        max_dd_trough = eq
        dd_start = current_dd_start
        dd_end = p["date"]
      end
    end

    pct = max_dd_peak > 0 ? (max_dd / max_dd_peak * 100) : 0

    # Find recovery date
    recovery_date = nil
    if dd_end
      past_trough = false
      equity_points.each do |p|
        past_trough = true if p["date"] == dd_end
        if past_trough && p["equity"] >= max_dd_peak
          recovery_date = p["date"]
          break
        end
      end
    end

    { pct: pct.round(2), amount: max_dd.round(2), peak: max_dd_peak.round(2), trough: max_dd_trough.round(2),
      start_date: dd_start, end_date: dd_end, recovery_date: recovery_date }
  end

  def compute_drawdown_periods(equity_points)
    return [] if equity_points.empty?

    periods = []
    peak = 0
    in_dd = false
    dd_start = nil
    dd_peak = 0

    equity_points.each_with_index do |p, i|
      eq = p["equity"]
      if eq > peak
        if in_dd
          periods << { start: dd_start, end: equity_points[i - 1]["date"], peak: dd_peak, trough_equity: equity_points[dd_start_idx..i].map { |x| x["equity"] }.min, recovery: p["date"], depth: ((dd_peak - equity_points[dd_start_idx..i].map { |x| x["equity"] }.min) / dd_peak * 100).round(1) }
          in_dd = false
        end
        peak = eq
      elsif eq < peak * 0.98 && !in_dd
        in_dd = true
        dd_start = p["date"]
        dd_peak = peak
      end
    end

    # Simplify: just return top 5 drawdown periods from the data
    compute_top_drawdowns(equity_points, 5)
  end

  def compute_top_drawdowns(equity_points, n)
    return [] if equity_points.length < 2

    drawdowns = []
    peak = equity_points.first["equity"]
    peak_date = equity_points.first["date"]
    trough = peak
    trough_date = peak_date
    in_drawdown = false

    equity_points.each do |p|
      eq = p["equity"]
      if eq >= peak
        if in_drawdown && peak > 0
          depth = ((peak - trough) / peak * 100).round(1)
          drawdowns << { start: peak_date, bottom: trough_date, recovery: p["date"], depth: depth, amount: (peak - trough).round(2) } if depth > 1
        end
        peak = eq
        peak_date = p["date"]
        trough = eq
        trough_date = p["date"]
        in_drawdown = false
      elsif eq < trough
        trough = eq
        trough_date = p["date"]
        in_drawdown = true
      end
    end

    # If still in drawdown
    if in_drawdown && peak > 0
      depth = ((peak - trough) / peak * 100).round(1)
      drawdowns << { start: peak_date, bottom: trough_date, recovery: nil, depth: depth, amount: (peak - trough).round(2) } if depth > 1
    end

    drawdowns.sort_by { |d| -d[:depth] }.first(n)
  end

  def compute_recovery_info(equity_points)
    return { recovering: false } if equity_points.empty?

    peak = equity_points.map { |p| p["equity"] }.max
    current = equity_points.last["equity"]

    if current >= peak
      { recovering: false, at_peak: true }
    else
      needed = peak - current
      # Estimate recovery based on average daily gain
      gains = equity_points.each_cons(2).map { |a, b| b["equity"] - a["equity"] }
      avg_daily = gains.any? ? gains.sum / gains.length : 0
      days_est = avg_daily > 0 ? (needed / avg_daily).ceil : nil

      { recovering: true, at_peak: false, needed: needed.round(2), peak: peak.round(2),
        progress_pct: (peak > 0 ? (current / peak * 100) : 0).round(1),
        avg_daily_gain: avg_daily.round(2), estimated_days: days_est }
    end
  end

  def compute_monthly_drawdowns(daily_pnl)
    return [] if daily_pnl.empty?

    by_month = daily_pnl.group_by { |date, _| date[0..6] }
    by_month.map do |month, days|
      cumulative = 0
      peak = 0
      max_dd = 0
      days.sort_by(&:first).each do |_, pnl|
        cumulative += pnl
        peak = cumulative if cumulative > peak
        dd = peak - cumulative
        max_dd = dd if dd > max_dd
      end
      total_pnl = days.sum { |_, v| v }
      { month: month, max_drawdown: max_dd.round(2), total_pnl: total_pnl.round(2), trade_days: days.count }
    end.sort_by { |m| m[:month] }.last(12)
  end

  def build_drawdown_chart(equity_points)
    return [] if equity_points.empty?

    peak = 0
    equity_points.map do |p|
      eq = p["equity"]
      peak = eq if eq > peak
      dd_pct = peak > 0 ? ((peak - eq) / peak * -100) : 0
      { date: p["date"], drawdown_pct: dd_pct.round(2), equity: eq }
    end
  end

  def extract_risk_metrics(risk, stats)
    {
      sharpe: (risk.is_a?(Hash) ? risk["sharpe_ratio"] : nil)&.to_f&.round(2),
      sortino: (risk.is_a?(Hash) ? risk["sortino_ratio"] : nil)&.to_f&.round(2),
      calmar: (risk.is_a?(Hash) ? risk["calmar_ratio"] : nil)&.to_f&.round(2),
      max_drawdown_pct: (risk.is_a?(Hash) ? risk["max_drawdown_pct"] : nil)&.to_f&.round(2),
      win_rate: (stats.is_a?(Hash) ? stats["win_rate"] : nil)&.to_f&.round(1),
      profit_factor: (stats.is_a?(Hash) ? stats["profit_factor"] : nil)&.to_f&.round(2),
      total_trades: (stats.is_a?(Hash) ? stats["total_trades"] : nil).to_i,
      avg_win: (stats.is_a?(Hash) ? stats["avg_win"] : nil)&.to_f&.round(2),
      avg_loss: (stats.is_a?(Hash) ? stats["avg_loss"] : nil)&.to_f&.round(2)
    }
  end

  def worst_trading_days(daily_pnl, n)
    daily_pnl.sort_by { |_, v| v }.first(n).map { |date, pnl| { date: date, pnl: pnl.round(2) } }
  end

  def generate_rules(metrics)
    rules = []
    if metrics[:max_drawdown_pct] && metrics[:max_drawdown_pct].abs > 10
      rules << { icon: "warning", color: "var(--negative)", text: "Your max drawdown exceeds 10%. Consider reducing position sizes." }
    end
    if metrics[:profit_factor] && metrics[:profit_factor] < 1.5
      rules << { icon: "info", color: "#f9a825", text: "Profit factor below 1.5 — focus on cutting losers faster." }
    end
    if metrics[:win_rate] && metrics[:win_rate] < 50
      rules << { icon: "trending_down", color: "var(--negative)", text: "Win rate below 50%. Ensure your winners are significantly larger than losers." }
    end
    rules << { icon: "shield", color: "var(--positive)", text: "Set a daily max loss of 2% of account to prevent catastrophic drawdowns." }
    rules << { icon: "pause_circle", color: "#1a73e8", text: "Take a mandatory break after 3 consecutive losses to reset mentally." }
    rules
  end
end

class SnapshotReportController < ApplicationController
  include ApiConnected

  def show
    @period = params[:period] || "30d"
    @as_of = Date.today

    stats_thread = Thread.new do
      api_client.overview
    rescue => e
      Rails.logger.error("snapshot stats: #{e.message}")
      {}
    end

    streaks_thread = Thread.new do
      api_client.streaks
    rescue => e
      Rails.logger.error("snapshot streaks: #{e.message}")
      {}
    end

    trades_thread = Thread.new do
      api_client.trades(per_page: 500, sort: "closed_at", direction: "desc")
    rescue => e
      Rails.logger.error("snapshot trades: #{e.message}")
      {}
    end

    budget_thread = Thread.new do
      budget_client.transactions(per_page: 200) if budget_api_token.present?
    rescue => e
      Rails.logger.error("snapshot budget: #{e.message}")
      {}
    end

    stats = stats_thread.value || {}
    streaks = streaks_thread.value || {}
    raw_trades = trades_thread.value || {}
    budget_data = budget_thread.value || {}

    trades = raw_trades.is_a?(Hash) ? (raw_trades["trades"] || raw_trades["data"] || []) : Array(raw_trades)
    daily_pnl = normalize_daily_pnl(stats)

    # Filter to period
    days = case @period
           when "7d" then 7
           when "30d" then 30
           when "90d" then 90
           when "ytd" then (Date.today - Date.new(Date.today.year, 1, 1)).to_i
           else 30
           end

    cutoff = Date.today - days
    period_pnl = daily_pnl.select { |d, _| Date.parse(d) >= cutoff rescue false }
    period_trades = trades.select do |t|
      d = (t["closed_at"] || t["created_at"]).to_s.slice(0, 10)
      Date.parse(d) >= cutoff rescue false
    end

    closed = period_trades.select { |t| t["status"] == "closed" || t["exit_price"].present? }
    wins = closed.count { |t| t["pnl"].to_f > 0 }

    @report = {
      period_label: period_label(@period),
      total_pnl: period_pnl.values.sum.round(2),
      total_trades: closed.length,
      win_rate: closed.any? ? (wins.to_f / closed.length * 100).round(1) : 0,
      wins: wins,
      losses: closed.length - wins,
      avg_win: closed.select { |t| t["pnl"].to_f > 0 }.map { |t| t["pnl"].to_f }.then { |a| a.any? ? (a.sum / a.length).round(2) : 0 },
      avg_loss: closed.select { |t| t["pnl"].to_f <= 0 }.map { |t| t["pnl"].to_f }.then { |a| a.any? ? (a.sum / a.length).round(2) : 0 },
      best_day: period_pnl.any? ? period_pnl.max_by { |_, v| v } : nil,
      worst_day: period_pnl.any? ? period_pnl.min_by { |_, v| v } : nil,
      trading_days: period_pnl.length,
      profitable_days: period_pnl.count { |_, v| v > 0 },
      top_symbols: top_symbols(closed, 5),
      daily_pnl_series: period_pnl.sort_by { |d, _| d }
    }

    # Streak
    cs = streaks.is_a?(Hash) ? streaks["current_streak"] : nil
    @report[:streak_count] = cs.is_a?(Hash) ? cs["count"].to_i : cs.to_i
    @report[:streak_type] = cs.is_a?(Hash) ? cs["type"] : (streaks.is_a?(Hash) ? streaks["streak_type"] : nil)

    # Budget summary for period
    if budget_data.is_a?(Hash) || budget_data.is_a?(Array)
      txns = budget_data.is_a?(Hash) ? (budget_data["transactions"] || []) : Array(budget_data)
      period_txns = txns.select do |t|
        d = (t["transaction_date"] || t["date"] || t["created_at"]).to_s.slice(0, 10)
        Date.parse(d) >= cutoff rescue false
      end
      @report[:total_spending] = period_txns.select { |t| t["transaction_type"] == "expense" }.sum { |t| t["amount"].to_f }.round(2)
      @report[:total_income] = period_txns.select { |t| t["transaction_type"] == "income" }.sum { |t| t["amount"].to_f }.round(2)
    end

    # Overall assessment
    @report[:grade] = compute_grade(@report)
  end

  private

  def normalize_daily_pnl(stats)
    raw = stats.is_a?(Hash) ? (stats["daily_pnl"] || {}) : {}
    pnl = raw.is_a?(Array) ? raw.to_h : raw
    pnl.transform_keys(&:to_s).transform_values(&:to_f)
  end

  def period_label(p)
    case p
    when "7d" then "Last 7 Days"
    when "30d" then "Last 30 Days"
    when "90d" then "Last 90 Days"
    when "ytd" then "Year to Date"
    else "Last 30 Days"
    end
  end

  def top_symbols(trades, n)
    trades.group_by { |t| t["symbol"] || "?" }.map do |sym, group|
      pnls = group.map { |t| t["pnl"].to_f }
      { name: sym, count: group.length, total_pnl: pnls.sum.round(2), win_rate: (pnls.count(&:positive?).to_f / [pnls.length, 1].max * 100).round(1) }
    end.sort_by { |s| -s[:total_pnl] }.first(n)
  end

  def compute_grade(report)
    score = 0
    score += 25 if report[:win_rate] >= 50
    score += 15 if report[:win_rate] >= 60
    score += 20 if report[:total_pnl] > 0
    score += 15 if report[:avg_win].abs > report[:avg_loss].abs
    score += 10 if report[:profitable_days] > report[:trading_days] / 2
    score += 15 if report[:trading_days] >= 15

    case score
    when 80..100 then "A"
    when 60..79 then "B"
    when 40..59 then "C"
    when 20..39 then "D"
    else "F"
    end
  end
end

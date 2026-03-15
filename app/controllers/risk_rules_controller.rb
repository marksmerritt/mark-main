class RiskRulesController < ApplicationController
  include ApiConnected

  def show
    stats_thread = Thread.new do
      api_client.overview
    rescue => e
      Rails.logger.error("risk_rules stats: #{e.message}")
      {}
    end

    trades_thread = Thread.new do
      api_client.trades(per_page: 200, sort: "closed_at", direction: "desc")
    rescue => e
      Rails.logger.error("risk_rules trades: #{e.message}")
      {}
    end

    streak_thread = Thread.new do
      api_client.streaks
    rescue => e
      Rails.logger.error("risk_rules streak: #{e.message}")
      {}
    end

    stats = stats_thread.value || {}
    raw_trades = trades_thread.value || {}
    streak_data = streak_thread.value || {}

    trades = extract_trades(raw_trades)
    daily_pnl = normalize_daily_pnl(stats)

    today_str = Date.today.to_s
    today_trades = trades.select do |t|
      date = (t["closed_at"] || t["exit_time"] || t["created_at"]).to_s.slice(0, 10)
      date == today_str
    end

    open_trades = trades.select { |t| t["status"] == "open" || t["exit_price"].blank? }

    @today_pnl = today_trades.sum { |t| t["pnl"].to_f }.round(2)
    @today_trade_count = today_trades.length
    @open_position_count = open_trades.length
    @biggest_loss_today = today_trades.map { |t| t["pnl"].to_f }.select(&:negative?).min || 0
    @biggest_loss_today = @biggest_loss_today.round(2)

    # Consecutive losses today
    today_pnls = today_trades.sort_by { |t| t["closed_at"] || t["created_at"] || "" }
                             .map { |t| t["pnl"].to_f }
    @consecutive_losses_today = count_trailing_losses(today_pnls)

    # Overall current streak from API
    cs = streak_data.is_a?(Hash) ? streak_data["current_streak"] : nil
    current_streak_count = cs.is_a?(Hash) ? cs["count"].to_i : cs.to_i
    current_streak_type = cs.is_a?(Hash) ? cs["type"] : (streak_data.is_a?(Hash) ? streak_data["streak_type"] : nil)
    @current_losing_streak = current_streak_type == "loss" ? current_streak_count.abs : 0

    # Max position size from open trades
    @max_position_value = open_trades.map { |t|
      qty = (t["quantity"] || t["shares"] || 0).to_f
      price = (t["entry_price"] || t["price"] || 0).to_f
      (qty * price).abs
    }.max || 0
    @max_position_value = @max_position_value.round(2)

    # Account balance for % calculations
    @account_balance = (stats.is_a?(Hash) ? (stats["account_balance"] || stats["total_equity"] || stats["balance"]) : nil).to_f
    @account_balance = 50_000.0 if @account_balance <= 0

    # Average R:R from recent trades
    recent_closed = trades.select { |t| t["status"] == "closed" || t["exit_price"].present? }.first(50)
    @avg_rr_ratio = compute_avg_rr(recent_closed)

    # Max % of account used in a single trade
    @max_pct_of_account = @account_balance > 0 ? (@max_position_value / @account_balance * 100).round(1) : 0

    # Rule breach history from daily_pnl (last 30 days)
    @rule_breach_history = compute_breach_history(daily_pnl)

    # Summary data for the view as JSON
    @metrics_json = {
      today_pnl: @today_pnl,
      today_trade_count: @today_trade_count,
      open_position_count: @open_position_count,
      biggest_loss_today: @biggest_loss_today,
      consecutive_losses_today: [@consecutive_losses_today, @current_losing_streak].max,
      max_position_value: @max_position_value,
      avg_rr_ratio: @avg_rr_ratio,
      max_pct_of_account: @max_pct_of_account,
      account_balance: @account_balance
    }.to_json
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

  def count_trailing_losses(pnls)
    count = 0
    pnls.reverse_each do |p|
      break if p >= 0
      count += 1
    end
    count
  end

  def compute_avg_rr(trades)
    ratios = trades.filter_map do |t|
      risk = (t["risk"] || t["stop_loss_amount"]).to_f.abs
      reward = t["pnl"].to_f
      next if risk <= 0
      (reward / risk).round(2)
    end
    return 0.0 if ratios.empty?
    (ratios.sum / ratios.length).round(2)
  end

  def compute_breach_history(daily_pnl)
    last_30 = daily_pnl.select do |date_str, _|
      begin
        Date.parse(date_str) >= Date.today - 30
      rescue
        false
      end
    end

    breach_days = last_30.count { |_, pnl| pnl < -500 }
    total_days = last_30.length
    worst_day = last_30.any? ? last_30.min_by { |_, v| v } : nil

    {
      breach_days: breach_days,
      total_days: total_days,
      worst_day_date: worst_day&.first,
      worst_day_pnl: worst_day&.last&.round(2),
      daily_pnl_last_30: last_30.sort_by { |d, _| d }.to_h
    }
  end
end

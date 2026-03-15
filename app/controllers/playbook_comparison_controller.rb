class PlaybookComparisonController < ApplicationController
  CURVE_COLORS = %w[#1a73e8 #e8710a #0d652d #c5221f #9334e6 #e91e63 #00bcd4 #795548].freeze

  def show
    trades_thread = Thread.new do
      api_client.trades(per_page: 2000, status: "closed")
    rescue => e
      Rails.logger.error("playbook_comparison trades: #{e.message}")
      {}
    end

    playbooks_thread = Thread.new do
      api_client.playbooks
    rescue => e
      Rails.logger.error("playbook_comparison playbooks: #{e.message}")
      {}
    end

    raw_trades = trades_thread.value || {}
    raw_playbooks = playbooks_thread.value || {}

    trades = normalize_trades(raw_trades)
    playbooks_list = normalize_playbooks(raw_playbooks)

    # Build a lookup of playbook id -> name
    playbook_names = {}
    playbooks_list.each do |pb|
      pb_id = (pb["id"] || pb[:id]).to_s
      pb_name = pb["name"] || pb[:name] || "Playbook #{pb_id}"
      playbook_names[pb_id] = pb_name
    end

    # Group trades by playbook_id
    grouped = trades.group_by { |t| (t["playbook_id"] || t["playbook"] || "").to_s }

    # Build stats per group
    @playbook_stats = []
    grouped.each do |pb_id, group_trades|
      name = if pb_id.blank?
               "No Playbook"
             else
               playbook_names[pb_id] || "Playbook #{pb_id}"
             end

      stats = compute_stats(group_trades, name, pb_id)
      @playbook_stats << stats
    end

    # Ensure "No Playbook" group exists even if empty
    unless @playbook_stats.any? { |s| s[:playbook_id].blank? }
      @playbook_stats << compute_stats([], "No Playbook", "")
    end

    # Sort: named playbooks first (alphabetically), "No Playbook" last
    @playbook_stats.sort_by! { |s| s[:name] == "No Playbook" ? [1, ""] : [0, s[:name].downcase] }

    # Assign colors for equity curves
    @playbook_stats.each_with_index do |s, i|
      s[:color] = CURVE_COLORS[i % CURVE_COLORS.length]
    end

    # Metrics for comparison table rows
    @metric_rows = build_metric_rows(@playbook_stats)
  end

  private

  def normalize_trades(raw)
    if raw.is_a?(Hash)
      raw["trades"] || raw["data"] || []
    elsif raw.is_a?(Array)
      raw
    else
      []
    end
  end

  def normalize_playbooks(raw)
    if raw.is_a?(Hash)
      raw["playbooks"] || raw["data"] || []
    elsif raw.is_a?(Array)
      raw
    else
      []
    end
  end

  def compute_stats(trades, name, pb_id)
    closed = trades.select { |t| t["status"] == "closed" || t["exit_price"].present? }
    pnls = closed.map { |t| t["pnl"].to_f }
    wins = pnls.select(&:positive?)
    losses = pnls.select { |v| v <= 0 }

    total_pnl = pnls.sum.round(2)
    trade_count = closed.length
    win_count = wins.length
    win_rate = trade_count > 0 ? (win_count.to_f / trade_count * 100).round(1) : 0.0
    avg_win = wins.any? ? (wins.sum / wins.length).round(2) : 0.0
    avg_loss = losses.any? ? (losses.sum / losses.length).round(2) : 0.0

    # Profit factor
    gross_wins = wins.sum
    gross_losses = losses.map(&:abs).sum
    profit_factor = gross_losses > 0 ? (gross_wins / gross_losses).round(2) : (gross_wins > 0 ? Float::INFINITY : 0.0)

    # Best / worst trade
    best_trade = closed.max_by { |t| t["pnl"].to_f }
    worst_trade = closed.min_by { |t| t["pnl"].to_f }

    # Avg hold time
    hold_minutes = closed.filter_map do |t|
      if t["entry_time"].present? && t["exit_time"].present?
        entry_t = Time.parse(t["entry_time"]) rescue nil
        exit_t = Time.parse(t["exit_time"]) rescue nil
        ((exit_t - entry_t) / 60.0).round(1) if entry_t && exit_t && exit_t > entry_t
      elsif t["hold_duration"].is_a?(Hash)
        t["hold_duration"]["minutes"].to_f
      end
    end
    avg_hold_min = hold_minutes.any? ? (hold_minutes.sum / hold_minutes.length).round(1) : nil
    avg_hold_display = format_minutes(avg_hold_min) if avg_hold_min

    # Top symbols
    top_symbols = closed.group_by { |t| t["symbol"] || "?" }.map do |sym, group|
      sym_pnls = group.map { |t| t["pnl"].to_f }
      { name: sym, count: group.length, total_pnl: sym_pnls.sum.round(2) }
    end.sort_by { |s| -s[:total_pnl] }.first(5)

    # Equity curve (cumulative P&L by trade close date)
    sorted_trades = closed.sort_by { |t| t["closed_at"] || t["exit_time"] || t["created_at"] || "" }
    cumulative = 0.0
    equity_curve = sorted_trades.map do |t|
      cumulative += t["pnl"].to_f
      date_str = (t["closed_at"] || t["exit_time"] || t["created_at"]).to_s.slice(0, 10)
      { date: date_str, value: cumulative.round(2) }
    end

    {
      name: name,
      playbook_id: pb_id,
      total_pnl: total_pnl,
      trade_count: trade_count,
      win_rate: win_rate,
      win_count: win_count,
      loss_count: trade_count - win_count,
      avg_win: avg_win,
      avg_loss: avg_loss,
      profit_factor: profit_factor,
      best_trade: best_trade,
      worst_trade: worst_trade,
      avg_hold_display: avg_hold_display,
      avg_hold_min: avg_hold_min,
      top_symbols: top_symbols,
      equity_curve: equity_curve
    }
  end

  def format_minutes(min)
    return nil unless min
    if min < 60
      "#{min.round(0)}m"
    elsif min < 1440
      "#{(min / 60.0).round(1)}h"
    else
      "#{(min / 1440.0).round(1)}d"
    end
  end

  def build_metric_rows(stats)
    [
      { label: "Total P&L", key: :total_pnl, format: :currency },
      { label: "Trade Count", key: :trade_count, format: :number },
      { label: "Win Rate", key: :win_rate, format: :percent },
      { label: "Wins", key: :win_count, format: :number },
      { label: "Losses", key: :loss_count, format: :number },
      { label: "Avg Win", key: :avg_win, format: :currency },
      { label: "Avg Loss", key: :avg_loss, format: :currency },
      { label: "Profit Factor", key: :profit_factor, format: :ratio },
      { label: "Avg Hold Time", key: :avg_hold_display, format: :text },
      { label: "Best Trade", key: :best_trade, format: :best_trade },
      { label: "Worst Trade", key: :worst_trade, format: :worst_trade }
    ]
  end
end

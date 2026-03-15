class TradeCompareController < ApplicationController
  before_action :require_api_connection

  include ActionView::Helpers::NumberHelper

  def show
    trade_result = api_client.trades(per_page: 500)
    all_trades = trade_result.is_a?(Hash) ? (trade_result["trades"] || []) : Array(trade_result)
    all_trades = all_trades.select { |t| t.is_a?(Hash) }
    @closed_trades = all_trades.select { |t| t["status"]&.downcase == "closed" && t["pnl"].present? }

    trade_a_param = params[:trade_a]
    trade_b_param = params[:trade_b]

    if trade_a_param.present? && trade_b_param.present? && @closed_trades.any?
      @trade_a = find_trade(trade_a_param)
      @trade_b = find_trade(trade_b_param)

      if @trade_a && @trade_b
        @metrics_a = compute_metrics(@trade_a)
        @metrics_b = compute_metrics(@trade_b)
        @comparison_rows = build_comparison_rows(@metrics_a, @metrics_b)
        @verdict = compute_verdict(@metrics_a, @metrics_b)
        @similar_trades = find_similar_trades(@trade_a, @trade_b)
      end
    end

    # Quick comparisons when no trades selected
    unless @trade_a && @trade_b
      if @closed_trades.length >= 2
        sorted_by_pnl = @closed_trades.sort_by { |t| t["pnl"].to_f }
        @worst_trade = sorted_by_pnl.first
        @best_trade = sorted_by_pnl.last

        sorted_by_date = @closed_trades.sort_by { |t| t["entry_time"].to_s }
        @first_trade = sorted_by_date.first
        @last_trade = sorted_by_date.last
      end
      @recent_trades = @closed_trades.sort_by { |t| t["entry_time"].to_s }.reverse.first(20)
    end
  rescue => e
    Rails.logger.error("TradeCompare error: #{e.message}")
    @closed_trades ||= []
    @recent_trades ||= []
  end

  private

  def find_trade(param)
    # Try as ID first
    found = @closed_trades.find { |t| t["id"].to_s == param.to_s }
    return found if found

    # Try as index
    idx = param.to_i
    if idx >= 0 && idx < @closed_trades.length
      @closed_trades[idx]
    end
  end

  def compute_metrics(trade)
    pnl = trade["pnl"].to_f
    entry = trade["entry_price"].to_f
    exit_p = trade["exit_price"].to_f
    quantity = trade["quantity"].to_f
    fees = trade["fees"].to_f
    stop = trade["stop_loss"].to_f
    target = trade["take_profit"].to_f
    side = (trade["side"] || trade["direction"] || "").downcase

    # Hold duration
    hold_display = nil
    hold_hours = nil
    entry_time = nil
    exit_time = nil
    if trade["entry_time"].present? && trade["exit_time"].present?
      begin
        entry_time = Time.parse(trade["entry_time"])
        exit_time = Time.parse(trade["exit_time"])
        hold_seconds = (exit_time - entry_time).to_f
        hold_hours = (hold_seconds / 3600.0).round(2)
        if hold_hours < 1
          hold_display = "#{(hold_seconds / 60).round(0)}m"
        elsif hold_hours < 24
          hold_display = "#{hold_hours.round(1)}h"
        else
          days = (hold_hours / 24.0).round(1)
          hold_display = "#{days}d"
        end
      rescue
        hold_display = nil
      end
    end

    # Return percentage
    return_pct = trade["return_percentage"].to_f
    if return_pct == 0 && entry > 0 && exit_p > 0
      if side.include?("long") || side.include?("buy")
        return_pct = ((exit_p - entry) / entry * 100).round(2)
      else
        return_pct = ((entry - exit_p) / entry * 100).round(2)
      end
    end

    # Risk/Reward
    risk_reward = nil
    if stop > 0 && target > 0 && entry > 0
      risk = (entry - stop).abs
      reward = (target - entry).abs
      risk_reward = (reward / risk).round(2) if risk > 0
    end

    # Net P&L
    net_pnl = pnl - fees.abs

    # Time of day
    time_of_day = nil
    if entry_time
      hour = entry_time.hour
      time_of_day = if hour < 10
        "Pre-Market / Early"
      elsif hour < 12
        "Morning"
      elsif hour < 14
        "Midday"
      else
        "Afternoon"
      end
    end

    # Day of week
    day_of_week = nil
    if entry_time
      day_of_week = entry_time.strftime("%A")
    end

    # Tags
    tags = trade["tags"] || []
    tag_names = tags.map { |t| t.is_a?(Hash) ? (t["name"] || t["label"] || t.to_s) : t.to_s }

    {
      id: trade["id"],
      symbol: (trade["symbol"] || "N/A").upcase,
      side: side,
      direction: side.include?("long") || side.include?("buy") ? "Long" : "Short",
      quantity: quantity,
      entry_price: entry,
      exit_price: exit_p,
      entry_date: trade["entry_time"].present? ? format_date(trade["entry_time"]) : "N/A",
      exit_date: trade["exit_time"].present? ? format_date(trade["exit_time"]) : "N/A",
      entry_time_raw: trade["entry_time"],
      exit_time_raw: trade["exit_time"],
      hold_display: hold_display || "N/A",
      hold_hours: hold_hours,
      pnl: pnl,
      return_pct: return_pct,
      fees: fees,
      net_pnl: net_pnl,
      stop_loss: stop,
      take_profit: target,
      risk_reward: risk_reward,
      time_of_day: time_of_day || "N/A",
      day_of_week: day_of_week || "N/A",
      notes: trade["notes"].to_s.strip,
      tags: tag_names,
      setup: trade["setup"],
      raw: trade
    }
  end

  def build_comparison_rows(a, b)
    rows = []

    rows << comparison_row("Symbol", a[:symbol], b[:symbol], :neutral)
    rows << comparison_row("Direction", a[:direction], b[:direction], :neutral)
    rows << comparison_row("Quantity", a[:quantity], b[:quantity], :neutral)
    rows << comparison_row("Entry Date", a[:entry_date], b[:entry_date], :neutral)
    rows << comparison_row("Exit Date", a[:exit_date], b[:exit_date], :neutral)
    rows << comparison_row("Duration", a[:hold_display], b[:hold_display], :neutral)
    rows << comparison_row("Entry Price", format_currency(a[:entry_price]), format_currency(b[:entry_price]), :neutral)
    rows << comparison_row("Exit Price", format_currency(a[:exit_price]), format_currency(b[:exit_price]), :neutral)
    rows << comparison_row("P&L", format_currency(a[:pnl]), format_currency(b[:pnl]), :higher_better, a[:pnl], b[:pnl])
    rows << comparison_row("Return %", "#{a[:return_pct]}%", "#{b[:return_pct]}%", :higher_better, a[:return_pct], b[:return_pct])
    rows << comparison_row("Fees", format_currency(a[:fees]), format_currency(b[:fees]), :lower_better, a[:fees], b[:fees])
    rows << comparison_row("Net P&L", format_currency(a[:net_pnl]), format_currency(b[:net_pnl]), :higher_better, a[:net_pnl], b[:net_pnl])
    rows << comparison_row("Stop Loss", a[:stop_loss] > 0 ? format_currency(a[:stop_loss]) : "None", b[:stop_loss] > 0 ? format_currency(b[:stop_loss]) : "None", :neutral)
    rows << comparison_row("Take Profit", a[:take_profit] > 0 ? format_currency(a[:take_profit]) : "None", b[:take_profit] > 0 ? format_currency(b[:take_profit]) : "None", :neutral)
    rows << comparison_row("Risk/Reward", a[:risk_reward] ? "#{a[:risk_reward]}:1" : "N/A", b[:risk_reward] ? "#{b[:risk_reward]}:1" : "N/A", :higher_better, a[:risk_reward].to_f, b[:risk_reward].to_f)
    rows << comparison_row("Time of Day", a[:time_of_day], b[:time_of_day], :neutral)
    rows << comparison_row("Day of Week", a[:day_of_week], b[:day_of_week], :neutral)
    rows << comparison_row("Notes", a[:notes].present? ? a[:notes].truncate(80) : "---", b[:notes].present? ? b[:notes].truncate(80) : "---", :neutral)
    rows << comparison_row("Tags", a[:tags].any? ? a[:tags].join(", ") : "---", b[:tags].any? ? b[:tags].join(", ") : "---", :neutral)

    rows
  end

  def comparison_row(label, val_a, val_b, mode, num_a = nil, num_b = nil)
    winner = nil
    if mode == :higher_better && num_a && num_b
      winner = num_a > num_b ? :a : (num_b > num_a ? :b : nil)
    elsif mode == :lower_better && num_a && num_b
      winner = num_a < num_b ? :a : (num_b < num_a ? :b : nil)
    end

    { label: label, val_a: val_a, val_b: val_b, winner: winner }
  end

  def compute_verdict(a, b)
    scores = { a: 0, b: 0 }
    reasons = []

    # P&L
    if a[:pnl] > b[:pnl]
      scores[:a] += 2
      reasons << { metric: "Higher P&L", winner: :a, detail: "#{format_currency(a[:pnl])} vs #{format_currency(b[:pnl])}" }
    elsif b[:pnl] > a[:pnl]
      scores[:b] += 2
      reasons << { metric: "Higher P&L", winner: :b, detail: "#{format_currency(b[:pnl])} vs #{format_currency(a[:pnl])}" }
    end

    # Return %
    if a[:return_pct] > b[:return_pct]
      scores[:a] += 1
      reasons << { metric: "Better Return %", winner: :a, detail: "#{a[:return_pct]}% vs #{b[:return_pct]}%" }
    elsif b[:return_pct] > a[:return_pct]
      scores[:b] += 1
      reasons << { metric: "Better Return %", winner: :b, detail: "#{b[:return_pct]}% vs #{a[:return_pct]}%" }
    end

    # Net P&L (after fees)
    if a[:net_pnl] > b[:net_pnl]
      scores[:a] += 1
      reasons << { metric: "Better Net P&L", winner: :a, detail: "#{format_currency(a[:net_pnl])} vs #{format_currency(b[:net_pnl])}" }
    elsif b[:net_pnl] > a[:net_pnl]
      scores[:b] += 1
      reasons << { metric: "Better Net P&L", winner: :b, detail: "#{format_currency(b[:net_pnl])} vs #{format_currency(a[:net_pnl])}" }
    end

    # Lower fees
    if a[:fees].abs < b[:fees].abs && (a[:fees] > 0 || b[:fees] > 0)
      scores[:a] += 1
      reasons << { metric: "Lower Fees", winner: :a, detail: "#{format_currency(a[:fees])} vs #{format_currency(b[:fees])}" }
    elsif b[:fees].abs < a[:fees].abs && (a[:fees] > 0 || b[:fees] > 0)
      scores[:b] += 1
      reasons << { metric: "Lower Fees", winner: :b, detail: "#{format_currency(b[:fees])} vs #{format_currency(a[:fees])}" }
    end

    # Risk/Reward
    if a[:risk_reward].to_f > 0 && b[:risk_reward].to_f > 0
      if a[:risk_reward] > b[:risk_reward]
        scores[:a] += 1
        reasons << { metric: "Better R:R", winner: :a, detail: "#{a[:risk_reward]}:1 vs #{b[:risk_reward]}:1" }
      elsif b[:risk_reward] > a[:risk_reward]
        scores[:b] += 1
        reasons << { metric: "Better R:R", winner: :b, detail: "#{b[:risk_reward]}:1 vs #{a[:risk_reward]}:1" }
      end
    end

    # Had stop loss
    if a[:stop_loss] > 0 && b[:stop_loss] == 0
      scores[:a] += 1
      reasons << { metric: "Used Stop Loss", winner: :a, detail: "Trade A had a stop loss" }
    elsif b[:stop_loss] > 0 && a[:stop_loss] == 0
      scores[:b] += 1
      reasons << { metric: "Used Stop Loss", winner: :b, detail: "Trade B had a stop loss" }
    end

    overall = if scores[:a] > scores[:b]
      :a
    elsif scores[:b] > scores[:a]
      :b
    else
      :tie
    end

    { scores: scores, reasons: reasons, overall: overall }
  end

  def find_similar_trades(trade_a, trade_b)
    similar = []

    # Same symbol as trade A or B
    [trade_a, trade_b].each do |ref|
      symbol = (ref["symbol"] || "").upcase
      next if symbol.empty?
      matches = @closed_trades.select { |t|
        (t["symbol"] || "").upcase == symbol &&
          t["id"].to_s != trade_a["id"].to_s &&
          t["id"].to_s != trade_b["id"].to_s
      }
      matches.each do |m|
        similar << {
          id: m["id"],
          symbol: (m["symbol"] || "N/A").upcase,
          side: m["side"],
          pnl: m["pnl"].to_f,
          entry_time: m["entry_time"],
          reason: "Same symbol (#{symbol})"
        }
      end
    end

    # Deduplicate and limit
    similar.uniq { |s| s[:id] }.first(10)
  rescue
    []
  end

  def format_date(time_str)
    Time.parse(time_str).strftime("%b %d, %Y %H:%M")
  rescue
    time_str.to_s
  end

  def format_currency(val)
    number_to_currency(val.to_f, precision: 2)
  rescue
    "$#{'%.2f' % val.to_f}"
  end
end

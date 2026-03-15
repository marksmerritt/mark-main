class ComparisonController < ApplicationController
  before_action :require_api_connection

  def show
    @account_size = (params[:account_size].presence || 100_000).to_f
    trade_ids = params[:trade_ids] || []

    # When no trades selected, show the selector UI (no redirect)
    unless trade_ids.length >= 2
      @trades = []
      @comparison = nil
      @search_trades = fetch_searchable_trades
      return
    end

    # Fetch trades in parallel threads for speed
    threads = trade_ids.first(4).map do |id|
      Thread.new { api_client.trade(id) }
    end
    fetched_trades = threads.map(&:value).compact.reject { |t| t.is_a?(Hash) && t["error"] }

    # Also fetch via the comparison API for aggregate data
    @comparison = api_client.compare_trades(trade_ids)
    api_trades = if @comparison.is_a?(Hash) && !@comparison["error"]
      @comparison["trades"] || []
    else
      []
    end

    # Prefer individually-fetched trades (more complete data), fall back to comparison API
    @trades = fetched_trades.any? ? fetched_trades : api_trades
    return if @trades.empty?

    # Build enhanced metrics for each trade
    @trade_metrics = @trades.map { |t| compute_trade_metrics(t) }

    # Determine the "winner" (best P&L)
    best_idx = @trade_metrics.each_with_index.max_by { |m, _| m[:pnl] }&.last
    @winner_id = @trade_metrics[best_idx][:id] if best_idx

    # Build execution quality metrics (existing logic, enhanced)
    @execution_metrics = @trades.map do |t|
      pnl = t["pnl"].to_f
      entry = t["entry_price"].to_f
      fees = t["fees"].to_f
      stop = t["stop_loss"].to_f
      target = t["take_profit"].to_f
      planned_rr = stop > 0 && target > 0 && entry > 0 ? ((target - entry).abs / (entry - stop).abs).round(2) : nil
      mfe = t["mfe"].to_f
      mae = t["mae"].to_f
      actual_rr = mae > 0 ? (mfe / mae).round(2) : nil
      gross_pnl = pnl + fees
      fee_drag = gross_pnl != 0 ? (fees / gross_pnl.abs * 100).round(1) : 0

      {
        id: t["id"],
        symbol: t["symbol"],
        pnl: pnl,
        planned_rr: planned_rr,
        actual_rr: actual_rr,
        mfe: mfe,
        mae: mae,
        fee_drag: fee_drag,
        emotional_state: t["emotional_state"],
        setup: t["setup"],
        confidence: t["confidence"]
      }
    end

    # Fetch searchable trades for the selector
    @search_trades = fetch_searchable_trades
  end

  private

  def fetch_searchable_trades
    result = api_client.trades(per_page: 200, status: "closed")
    all = result.is_a?(Hash) ? (result["trades"] || []) : (result || [])
    all.map do |t|
      {
        id: t["id"],
        symbol: t["symbol"],
        side: t["side"],
        pnl: t["pnl"],
        entry_time: t["entry_time"],
        status: t["status"]
      }
    end
  rescue
    []
  end

  def compute_trade_metrics(t)
    pnl = t["pnl"].to_f
    entry = t["entry_price"].to_f
    exit_p = t["exit_price"].to_f
    quantity = t["quantity"].to_f
    fees = t["fees"].to_f
    stop = t["stop_loss"].to_f
    target = t["take_profit"].to_f
    high = t["high"].to_f
    low = t["low"].to_f
    side = t["side"].to_s.downcase

    # Hold duration
    hold_hours = nil
    hold_display = nil
    if t["entry_time"].present? && t["exit_time"].present?
      entry_time = Time.parse(t["entry_time"])
      exit_time = Time.parse(t["exit_time"])
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
    elsif t["hold_duration"].is_a?(Hash)
      minutes = t["hold_duration"]["minutes"].to_f
      hold_hours = (minutes / 60.0).round(2)
      hold_display = t["hold_duration"]["display"]
    end

    # R-multiple: P&L / risk_per_share * quantity
    r_multiple = nil
    if stop > 0 && entry > 0
      risk_per_share = (entry - stop).abs
      if risk_per_share > 0
        r_multiple = (pnl / (risk_per_share * quantity)).round(2) if quantity > 0
      end
    end

    # Risk/reward ratio (planned)
    risk_reward = nil
    if stop > 0 && target > 0 && entry > 0
      risk = (entry - stop).abs
      reward = (target - entry).abs
      risk_reward = (reward / risk).round(2) if risk > 0
    end

    # Execution efficiency: how close entry was to the best price of the day
    execution_efficiency = nil
    if high > 0 && low > 0 && entry > 0 && high != low
      range = high - low
      if side == "long" || side == "buy"
        # For longs, best entry is the low
        execution_efficiency = ((high - entry) / range * 100).round(1)
      else
        # For shorts, best entry is the high
        execution_efficiency = ((entry - low) / range * 100).round(1)
      end
      execution_efficiency = execution_efficiency.clamp(0, 100)
    end

    # P&L per hour held
    pnl_per_hour = nil
    if hold_hours && hold_hours > 0
      pnl_per_hour = (pnl / hold_hours).round(2)
    end

    # Position size relative to account
    position_value = entry * quantity if entry > 0 && quantity > 0
    position_pct = position_value ? (position_value / @account_size * 100).round(2) : nil

    # Return percentage
    return_pct = t["return_percentage"].to_f
    if return_pct == 0 && entry > 0 && exit_p > 0
      if side == "long" || side == "buy"
        return_pct = ((exit_p - entry) / entry * 100).round(2)
      else
        return_pct = ((entry - exit_p) / entry * 100).round(2)
      end
    end

    {
      id: t["id"],
      symbol: t["symbol"],
      side: t["side"],
      status: t["status"],
      entry_price: entry,
      exit_price: exit_p,
      quantity: quantity,
      pnl: pnl,
      return_pct: return_pct,
      fees: fees,
      stop_loss: stop,
      take_profit: target,
      entry_time: t["entry_time"],
      exit_time: t["exit_time"],
      hold_hours: hold_hours,
      hold_display: hold_display,
      r_multiple: r_multiple,
      risk_reward: risk_reward,
      execution_efficiency: execution_efficiency,
      pnl_per_hour: pnl_per_hour,
      position_value: position_value,
      position_pct: position_pct,
      tags: t["tags"] || [],
      notes: t["notes"],
      high: high,
      low: low
    }
  end
end

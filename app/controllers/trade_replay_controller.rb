class TradeReplayController < ApplicationController
  before_action :require_api_connection

  def show
    # Fetch all closed trades sorted by date
    result = api_client.trades(per_page: 2000, status: "closed")
    all_trades = result.is_a?(Hash) ? (result["trades"] || []) : Array(result)
    all_trades = all_trades.select { |t| t.is_a?(Hash) }

    # Sort by exit time
    @trades = all_trades.sort_by { |t| t["exit_time"] || t["entry_time"] || "" }

    # Find current trade (from params or default to latest)
    @current_index = if params[:trade_id]
      @trades.index { |t| t["id"].to_s == params[:trade_id].to_s } || (@trades.length - 1)
    elsif params[:index]
      params[:index].to_i.clamp(0, [@trades.length - 1, 0].max)
    else
      [@trades.length - 1, 0].max
    end

    @trade = @trades[@current_index]
    return unless @trade

    # Navigation
    @prev_index = @current_index > 0 ? @current_index - 1 : nil
    @next_index = @current_index < @trades.length - 1 ? @current_index + 1 : nil

    # Build running equity curve up to current trade
    @running_equity = []
    running = 0
    @trades.first(@current_index + 1).each_with_index do |t, i|
      running += t["pnl"].to_f
      @running_equity << { index: i, pnl: t["pnl"].to_f, cumulative: running.round(2), symbol: t["symbol"] }
    end
    @total_pnl_at_point = running.round(2)

    # Stats up to this point
    trades_so_far = @trades.first(@current_index + 1)
    wins = trades_so_far.count { |t| t["pnl"].to_f > 0 }
    losses = trades_so_far.count { |t| t["pnl"].to_f < 0 }
    @stats_at_point = {
      trade_number: @current_index + 1,
      total_trades: @trades.length,
      wins: wins,
      losses: losses,
      win_rate: trades_so_far.any? ? (wins.to_f / trades_so_far.count * 100).round(1) : 0,
      cumulative_pnl: @total_pnl_at_point,
      avg_pnl: trades_so_far.any? ? (trades_so_far.sum { |t| t["pnl"].to_f } / trades_so_far.count).round(2) : 0,
      best_so_far: trades_so_far.map { |t| t["pnl"].to_f }.max || 0,
      worst_so_far: trades_so_far.map { |t| t["pnl"].to_f }.min || 0
    }

    # Current streak at this point
    streak = 0
    streak_type = nil
    trades_so_far.reverse_each do |t|
      pnl = t["pnl"].to_f
      if streak_type.nil?
        streak_type = pnl >= 0 ? :win : :loss
        streak = 1
      elsif (streak_type == :win && pnl >= 0) || (streak_type == :loss && pnl < 0)
        streak += 1
      else
        break
      end
    end
    @stats_at_point[:streak] = streak
    @stats_at_point[:streak_type] = streak_type

    # Max drawdown up to this point
    peak = 0
    max_dd = 0
    @running_equity.each do |e|
      peak = e[:cumulative] if e[:cumulative] > peak
      dd = peak - e[:cumulative]
      max_dd = dd if dd > max_dd
    end
    @stats_at_point[:max_drawdown] = max_dd.round(2)

    # Trade details
    @entry = @trade["entry_price"].to_f
    @exit = @trade["exit_price"].to_f
    @pnl = @trade["pnl"].to_f
    @side = @trade["side"]
    @quantity = @trade["quantity"].to_f
    @stop = @trade["stop_loss"].to_f
    @target = @trade["take_profit"].to_f
    @fees = @trade["fees"].to_f

    # Hold duration
    if @trade["entry_time"].present? && @trade["exit_time"].present?
      seconds = (Time.parse(@trade["exit_time"]) - Time.parse(@trade["entry_time"])).to_f
      @hold_display = if seconds < 3600
        "#{(seconds / 60).round(0)}m"
      elsif seconds < 86400
        "#{(seconds / 3600).round(1)}h"
      else
        "#{(seconds / 86400).round(1)}d"
      end
    end

    # R-multiple
    if @stop > 0 && @entry > 0 && @quantity > 0
      risk_per_share = (@entry - @stop).abs
      @r_multiple = risk_per_share > 0 ? (@pnl / (risk_per_share * @quantity)).round(2) : nil
    end

    # Return %
    @return_pct = @trade["return_percentage"].to_f
    if @return_pct == 0 && @entry > 0 && @exit > 0
      if @side&.downcase&.match?(/long|buy/)
        @return_pct = ((@exit - @entry) / @entry * 100).round(2)
      else
        @return_pct = ((@entry - @exit) / @entry * 100).round(2)
      end
    end

    # Context: nearby trades (5 before, 5 after)
    context_start = [@current_index - 5, 0].max
    context_end = [@current_index + 5, @trades.length - 1].min
    @context_trades = (context_start..context_end).map { |i|
      t = @trades[i]
      { index: i, symbol: t["symbol"], pnl: t["pnl"].to_f, date: (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 10), current: i == @current_index }
    }

    # Filters for jump-to
    @symbols = @trades.map { |t| t["symbol"] }.compact.uniq.sort
  end

  include ActionView::Helpers::NumberHelper
end

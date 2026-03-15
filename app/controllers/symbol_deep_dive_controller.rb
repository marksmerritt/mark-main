class SymbolDeepDiveController < ApplicationController
  before_action :require_api_connection

  def show
    # Fetch all closed trades (paginate up to 500)
    all_trades = []
    page = 1
    loop do
      result = api_client.trades(per_page: 200, page: page, sort: "exit_time", direction: "asc")
      batch = if result.is_a?(Hash)
                result["trades"] || result["data"] || []
              elsif result.is_a?(Array)
                result
              else
                []
              end
      batch = batch.select { |t| t.is_a?(Hash) }
      all_trades.concat(batch)
      break if batch.length < 200 || all_trades.length >= 500
      page += 1
    end

    all_trades = all_trades.first(500)
    closed_trades = all_trades.select { |t| t["status"]&.downcase == "closed" && t["pnl"].present? }

    # Build unique symbol list for dropdown
    @symbols = closed_trades.map { |t| (t["symbol"] || "").upcase }.reject(&:empty?).uniq.sort

    # Determine selected symbol
    @symbol = if params[:symbol].present?
                params[:symbol].upcase
              elsif @symbols.any?
                # Default to most-traded symbol
                closed_trades.group_by { |t| (t["symbol"] || "").upcase }
                             .max_by { |_, v| v.count }
                             &.first || @symbols.first
              else
                nil
              end

    # Filter trades to selected symbol
    @trades = @symbol ? closed_trades.select { |t| (t["symbol"] || "").upcase == @symbol } : []
    @trades = @trades.sort_by { |t| t["exit_time"] || t["entry_time"] || "" }

    compute_stats if @trades.any?
  rescue => e
    Rails.logger.error("SymbolDeepDive error: #{e.message}")
    @symbols ||= []
    @trades ||= []
    @symbol ||= nil
    @error = "Unable to load trade data. Please try again later."
  end

  private

  def compute_stats
    pnls = @trades.map { |t| t["pnl"].to_f }
    wins = @trades.select { |t| t["pnl"].to_f > 0 }
    losses = @trades.select { |t| t["pnl"].to_f < 0 }

    # Basic stats
    @total_pnl = pnls.sum.round(2)
    @trade_count = @trades.count
    @win_count = wins.count
    @loss_count = losses.count
    @win_rate = @trade_count > 0 ? (@win_count.to_f / @trade_count * 100).round(1) : 0
    @avg_win = wins.any? ? (wins.sum { |t| t["pnl"].to_f } / wins.count).round(2) : 0
    @avg_loss = losses.any? ? (losses.sum { |t| t["pnl"].to_f } / losses.count).round(2) : 0
    gross_loss = losses.sum { |t| t["pnl"].to_f.abs }
    @profit_factor = gross_loss > 0 ? (wins.sum { |t| t["pnl"].to_f } / gross_loss).round(2) : 0

    # Equity curve
    running = 0
    @equity_curve = @trades.map do |t|
      running += t["pnl"].to_f
      { date: (t["exit_time"] || t["entry_time"]).to_s.slice(0, 10), value: running.round(2) }
    end

    # Hold time analysis
    hold_minutes_list = @trades.filter_map do |t|
      if t["entry_time"].present? && t["exit_time"].present?
        begin
          ((Time.parse(t["exit_time"]) - Time.parse(t["entry_time"])) / 60.0).abs.round(0)
        rescue
          nil
        end
      end
    end
    @avg_hold_minutes = hold_minutes_list.any? ? (hold_minutes_list.sum.to_f / hold_minutes_list.count).round(0) : 0

    # Time analysis: day of week
    day_names = %w[Sunday Monday Tuesday Wednesday Thursday Friday Saturday]
    day_groups = @trades.group_by do |t|
      date_str = (t["entry_time"] || t["exit_time"]).to_s.slice(0, 10)
      begin
        Date.parse(date_str).wday
      rescue
        nil
      end
    end.reject { |k, _| k.nil? }

    @day_stats = day_names.each_with_index.map do |name, idx|
      trades = day_groups[idx] || []
      pnl = trades.sum { |t| t["pnl"].to_f }.round(2)
      count = trades.count
      w = trades.count { |t| t["pnl"].to_f > 0 }
      wr = count > 0 ? (w.to_f / count * 100).round(1) : 0
      { name: name, pnl: pnl, count: count, win_rate: wr }
    end
    @best_day = @day_stats.select { |d| d[:count] > 0 }.max_by { |d| d[:pnl] }
    @worst_day = @day_stats.select { |d| d[:count] > 0 }.min_by { |d| d[:pnl] }

    # Time analysis: hour of day
    hour_groups = @trades.group_by do |t|
      begin
        Time.parse(t["entry_time"].to_s).hour
      rescue
        nil
      end
    end.reject { |k, _| k.nil? }

    @hour_stats = (0..23).map do |h|
      trades = hour_groups[h] || []
      pnl = trades.sum { |t| t["pnl"].to_f }.round(2)
      count = trades.count
      w = trades.count { |t| t["pnl"].to_f > 0 }
      wr = count > 0 ? (w.to_f / count * 100).round(1) : 0
      label = if h == 0 then "12a"
              elsif h < 12 then "#{h}a"
              elsif h == 12 then "12p"
              else "#{h - 12}p"
              end
      { hour: h, label: label, pnl: pnl, count: count, win_rate: wr }
    end
    active_hours = @hour_stats.select { |h| h[:count] > 0 }
    @best_hour = active_hours.max_by { |h| h[:pnl] }
    @worst_hour = active_hours.min_by { |h| h[:pnl] }

    # P&L distribution
    if pnls.any?
      min_pnl = pnls.min
      max_pnl = pnls.max
      range = max_pnl - min_pnl
      if range > 0
        bin_count = [10, @trade_count].min
        bin_size = range / bin_count.to_f
        @pnl_bins = bin_count.times.map do |i|
          low = min_pnl + (i * bin_size)
          high = low + bin_size
          count = pnls.count { |p| i == bin_count - 1 ? p >= low && p <= high : p >= low && p < high }
          mid = ((low + high) / 2).round(0)
          { low: low.round(0), high: high.round(0), mid: mid, count: count }
        end
      else
        @pnl_bins = [{ low: min_pnl.round(0), high: max_pnl.round(0), mid: min_pnl.round(0), count: @trade_count }]
      end
    else
      @pnl_bins = []
    end

    # Side analysis
    longs = @trades.select { |t| (t["side"] || t["direction"] || "").downcase.match?(/long|buy/) }
    shorts = @trades.select { |t| (t["side"] || t["direction"] || "").downcase.match?(/short|sell/) }

    @long_stats = compute_side_stats(longs)
    @short_stats = compute_side_stats(shorts)

    # Monthly trend
    monthly_groups = @trades.group_by do |t|
      (t["exit_time"] || t["entry_time"]).to_s.slice(0, 7)
    end.reject { |k, _| k.nil? || k.empty? }

    @monthly_data = monthly_groups.sort_by { |k, _| k }.map do |month, trades|
      pnl = trades.sum { |t| t["pnl"].to_f }.round(2)
      count = trades.count
      w = trades.count { |t| t["pnl"].to_f > 0 }
      wr = count > 0 ? (w.to_f / count * 100).round(1) : 0
      { month: month, pnl: pnl, count: count, win_rate: wr }
    end

    # Last 20 trades
    @recent_trades = @trades.last(20).reverse.map do |t|
      hold = nil
      if t["entry_time"].present? && t["exit_time"].present?
        begin
          hold = ((Time.parse(t["exit_time"]) - Time.parse(t["entry_time"])) / 60.0).abs.round(0)
        rescue
          nil
        end
      end
      {
        date: (t["exit_time"] || t["entry_time"]).to_s.slice(0, 10),
        side: t["side"] || t["direction"] || "—",
        entry: t["entry_price"].to_f,
        exit: t["exit_price"].to_f,
        pnl: t["pnl"].to_f.round(2),
        hold_minutes: hold,
        quantity: t["quantity"]
      }
    end
  end

  def compute_side_stats(trades)
    return { count: 0, pnl: 0, win_rate: 0, avg_pnl: 0, avg_win: 0, avg_loss: 0 } if trades.empty?
    wins = trades.select { |t| t["pnl"].to_f > 0 }
    losses = trades.select { |t| t["pnl"].to_f < 0 }
    pnl = trades.sum { |t| t["pnl"].to_f }.round(2)
    {
      count: trades.count,
      pnl: pnl,
      win_rate: (wins.count.to_f / trades.count * 100).round(1),
      avg_pnl: (pnl / trades.count).round(2),
      avg_win: wins.any? ? (wins.sum { |t| t["pnl"].to_f } / wins.count).round(2) : 0,
      avg_loss: losses.any? ? (losses.sum { |t| t["pnl"].to_f } / losses.count).round(2) : 0
    }
  end

  def format_hold_time(minutes)
    return "—" unless minutes && minutes > 0
    if minutes < 60
      "#{minutes}m"
    elsif minutes < 1440
      "#{(minutes / 60.0).round(1)}h"
    else
      "#{(minutes / 1440.0).round(1)}d"
    end
  end
  helper_method :format_hold_time
end

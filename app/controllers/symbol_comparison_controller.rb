class SymbolComparisonController < ApplicationController
  before_action :require_api_connection

  def show
    @symbols = Array(params[:symbols]).reject(&:blank?).map(&:upcase).uniq.first(8)

    # Fetch all closed trades
    result = api_client.trades(per_page: 2000, status: "closed")
    all_trades = result.is_a?(Hash) ? (result["trades"] || []) : Array(result)

    # Available symbols for the picker
    @available_symbols = all_trades.map { |t| t["symbol"] }.compact.uniq.sort
    @total_trade_count = all_trades.count

    # If no symbols selected, default to top 5 by trade count
    if @symbols.empty?
      top = all_trades.group_by { |t| t["symbol"] }.sort_by { |_, v| -v.count }.first(5)
      @symbols = top.map(&:first)
    end

    # Build per-symbol metrics
    @symbol_data = {}
    @symbols.each do |sym|
      trades = all_trades.select { |t| t["symbol"]&.upcase == sym }
      next if trades.empty?

      wins = trades.select { |t| t["pnl"].to_f > 0 }
      losses = trades.select { |t| t["pnl"].to_f < 0 }
      pnls = trades.map { |t| t["pnl"].to_f }

      total_pnl = pnls.sum
      avg_pnl = pnls.any? ? (total_pnl / pnls.count).round(2) : 0
      win_rate = trades.any? ? (wins.count.to_f / trades.count * 100).round(1) : 0
      avg_win = wins.any? ? (wins.sum { |t| t["pnl"].to_f } / wins.count).round(2) : 0
      avg_loss = losses.any? ? (losses.sum { |t| t["pnl"].to_f } / losses.count).round(2) : 0
      profit_factor = losses.any? && losses.sum { |t| t["pnl"].to_f.abs } > 0 ?
        (wins.sum { |t| t["pnl"].to_f } / losses.sum { |t| t["pnl"].to_f.abs }).round(2) : 0
      best_trade = pnls.max || 0
      worst_trade = pnls.min || 0
      max_consecutive_wins = max_streak(trades, :win)
      max_consecutive_losses = max_streak(trades, :loss)

      # Hold time
      hold_minutes = trades.filter_map { |t|
        if t["entry_time"].present? && t["exit_time"].present?
          ((Time.parse(t["exit_time"]) - Time.parse(t["entry_time"])) / 60.0).round(0)
        elsif t["hold_duration"].is_a?(Hash)
          t["hold_duration"]["minutes"].to_f
        end
      }
      avg_hold = hold_minutes.any? ? (hold_minutes.sum / hold_minutes.count).round(0) : nil

      # Return percentages
      returns = trades.filter_map { |t|
        rp = t["return_percentage"].to_f
        rp != 0 ? rp : nil
      }
      avg_return = returns.any? ? (returns.sum / returns.count).round(2) : 0

      # Equity curve for this symbol
      running = 0
      equity_curve = trades.sort_by { |t| t["exit_time"] || t["entry_time"] || "" }.map { |t|
        running += t["pnl"].to_f
        running.round(2)
      }

      # Monthly P&L
      monthly = {}
      trades.each do |t|
        month = (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 7)
        next unless month
        monthly[month] ||= 0
        monthly[month] += t["pnl"].to_f
      end

      # Side breakdown
      longs = trades.select { |t| t["side"]&.downcase&.match?(/long|buy/) }
      shorts = trades.select { |t| t["side"]&.downcase&.match?(/short|sell/) }

      @symbol_data[sym] = {
        count: trades.count,
        wins: wins.count,
        losses: losses.count,
        total_pnl: total_pnl.round(2),
        avg_pnl: avg_pnl,
        win_rate: win_rate,
        avg_win: avg_win,
        avg_loss: avg_loss,
        profit_factor: profit_factor,
        best_trade: best_trade,
        worst_trade: worst_trade,
        max_win_streak: max_consecutive_wins,
        max_loss_streak: max_consecutive_losses,
        avg_hold_minutes: avg_hold,
        avg_return: avg_return,
        equity_curve: equity_curve,
        monthly_pnl: monthly,
        long_count: longs.count,
        short_count: shorts.count,
        long_pnl: longs.sum { |t| t["pnl"].to_f }.round(2),
        short_pnl: shorts.sum { |t| t["pnl"].to_f }.round(2)
      }
    end

    # Rankings
    @ranked_by_pnl = @symbol_data.sort_by { |_, d| -d[:total_pnl] }
    @ranked_by_win_rate = @symbol_data.sort_by { |_, d| -d[:win_rate] }
    @ranked_by_count = @symbol_data.sort_by { |_, d| -d[:count] }

    # Best & worst performers
    @best_symbol = @ranked_by_pnl.first
    @worst_symbol = @ranked_by_pnl.last
  end

  private

  def max_streak(trades, type)
    sorted = trades.sort_by { |t| t["exit_time"] || t["entry_time"] || "" }
    max = 0
    current = 0
    sorted.each do |t|
      if (type == :win && t["pnl"].to_f > 0) || (type == :loss && t["pnl"].to_f < 0)
        current += 1
        max = current if current > max
      else
        current = 0
      end
    end
    max
  end
end

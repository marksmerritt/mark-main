class EquitySimulatorController < ApplicationController
  before_action :require_api_connection

  def show
    trade_result = begin
      api_client.trades(per_page: 200, sort: "closed_at", direction: "asc")
    rescue => e
      Rails.logger.error("EquitySimulator: Failed to fetch trades: #{e.message}")
      nil
    end

    all_trades = if trade_result.is_a?(Hash)
                   trade_result["trades"] || []
                 else
                   Array(trade_result)
                 end
    all_trades = all_trades.select { |t| t.is_a?(Hash) }

    @trades = all_trades
      .select { |t| t["status"]&.downcase == "closed" && t["pnl"].present? }
      .sort_by { |t| t["closed_at"] || t["exit_time"] || t["entry_time"] || "" }

    # Build actual equity curve
    cumulative = 0.0
    @equity_curve = @trades.map do |t|
      cumulative += t["pnl"].to_f
      cumulative.round(2)
    end

    # Compute baseline stats
    pnls = @trades.map { |t| t["pnl"].to_f }
    wins = @trades.select { |t| t["pnl"].to_f > 0 }
    losses = @trades.select { |t| t["pnl"].to_f <= 0 }
    total_count = @trades.count
    total_pnl = pnls.sum

    @baseline = {
      total_pnl: total_pnl.round(2),
      trade_count: total_count,
      win_count: wins.count,
      loss_count: losses.count,
      win_rate: total_count > 0 ? (wins.count.to_f / total_count * 100).round(1) : 0,
      max_drawdown: compute_max_drawdown(pnls),
      best_trade: pnls.any? ? pnls.max.round(2) : 0,
      worst_trade: pnls.any? ? pnls.min.round(2) : 0,
      sharpe: compute_sharpe(pnls)
    }

    # Serialize trades as JSON for Stimulus controller
    @trades_json = @trades.map { |t|
      {
        pnl: t["pnl"].to_f.round(2),
        symbol: t["symbol"] || "Unknown",
        date: (t["closed_at"] || t["exit_time"] || t["entry_time"]).to_s.slice(0, 10),
        entry_price: t["entry_price"].to_f,
        exit_price: t["exit_price"].to_f,
        quantity: t["quantity"].to_f
      }
    }.to_json
  end

  private

  def compute_max_drawdown(pnls)
    peak = 0.0
    max_dd = 0.0
    running = 0.0
    pnls.each do |pnl|
      running += pnl
      peak = running if running > peak
      dd = peak - running
      max_dd = dd if dd > max_dd
    end
    max_dd.round(2)
  end

  def compute_sharpe(pnls)
    return 0.0 if pnls.length < 2
    mean = pnls.sum / pnls.length
    variance = pnls.sum { |p| (p - mean) ** 2 } / pnls.length
    std_dev = Math.sqrt(variance)
    return 0.0 if std_dev == 0
    (mean / std_dev).round(2)
  end
end

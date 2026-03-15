class SizingBacktestController < ApplicationController
  include ApiConnected

  def show
    trades_thread = Thread.new do
      fetch_all_trades
    rescue => e
      Rails.logger.error("sizing_backtest trades: #{e.message}")
      []
    end

    trades = trades_thread.value || []
    closed = trades.select { |t| t["status"] == "closed" || t["exit_price"].present? }
                   .sort_by { |t| t["closed_at"] || t["created_at"] || "" }

    @starting_capital = 10_000.0
    @trades_data = closed.map do |t|
      {
        symbol: t["symbol"] || "?",
        pnl: t["pnl"].to_f,
        pnl_pct: t["entry_price"].to_f > 0 ? (t["pnl"].to_f / (t["entry_price"].to_f * (t["quantity"] || 1).to_f) * 100).round(4) : 0,
        date: (t["closed_at"] || t["created_at"]).to_s.slice(0, 10),
        entry_price: t["entry_price"].to_f,
        quantity: t["quantity"].to_f,
        side: t["side"] || "long"
      }
    end

    # Compute actual equity curve
    @actual_curve = compute_equity(@trades_data.map { |t| t[:pnl] }, @starting_capital)

    # Compute strategies
    win_rate = closed.any? ? closed.count { |t| t["pnl"].to_f > 0 }.to_f / closed.length : 0.5
    avg_win = closed.select { |t| t["pnl"].to_f > 0 }.map { |t| t["pnl"].to_f }
    avg_loss = closed.select { |t| t["pnl"].to_f <= 0 }.map { |t| t["pnl"].to_f.abs }
    avg_w = avg_win.any? ? avg_win.sum / avg_win.length : 1
    avg_l = avg_loss.any? ? avg_loss.sum / avg_loss.length : 1
    kelly_fraction = avg_l > 0 ? (win_rate - (1 - win_rate) / (avg_w / avg_l)).clamp(0, 0.25) : 0.02

    @strategies = []

    # 1. Fixed Fractional (1% risk)
    @strategies << build_strategy("Fixed 1% Risk", closed, @starting_capital) do |equity, _trade|
      equity * 0.01
    end

    # 2. Fixed Fractional (2% risk)
    @strategies << build_strategy("Fixed 2% Risk", closed, @starting_capital) do |equity, _trade|
      equity * 0.02
    end

    # 3. Kelly Criterion
    @strategies << build_strategy("Kelly Criterion", closed, @starting_capital) do |equity, _trade|
      equity * kelly_fraction
    end

    # 4. Half Kelly
    @strategies << build_strategy("Half Kelly", closed, @starting_capital) do |equity, _trade|
      equity * (kelly_fraction / 2)
    end

    # 5. Anti-Martingale (increase after wins)
    streak = 0
    @strategies << build_anti_martingale("Anti-Martingale", closed, @starting_capital)

    # 6. Fixed Dollar ($100)
    @strategies << build_strategy("Fixed $100", closed, @starting_capital) do |_equity, _trade|
      100.0
    end

    @kelly_fraction = (kelly_fraction * 100).round(2)
    @win_rate = (win_rate * 100).round(1)
    @trade_count = closed.length
  end

  private

  def fetch_all_trades
    all = []
    page = 1
    loop do
      result = api_client.trades(page: page, per_page: 200, sort: "closed_at", direction: "asc")
      batch = result.is_a?(Hash) ? (result["trades"] || result["data"] || []) : Array(result)
      break if batch.empty?
      all.concat(batch)
      break if batch.length < 200
      page += 1
    end
    all
  end

  def compute_equity(pnls, start)
    curve = [start]
    pnls.each { |pnl| curve << curve.last + pnl }
    curve
  end

  def build_strategy(name, trades, starting_capital)
    equity = starting_capital
    curve = [equity]
    max_equity = equity
    max_dd = 0

    trades.each do |t|
      pnl = t["pnl"].to_f
      risk_amount = yield(equity, t)
      risk_amount = [risk_amount, equity * 0.5].min  # Cap at 50% of equity

      # Scale P&L by risk amount relative to actual risk
      actual_risk = t["entry_price"].to_f * (t["quantity"] || 1).to_f
      if actual_risk > 0 && risk_amount > 0
        scale = risk_amount / actual_risk
        scaled_pnl = pnl * scale
      else
        scaled_pnl = pnl
      end

      equity += scaled_pnl
      equity = [equity, 0].max
      curve << equity

      max_equity = [max_equity, equity].max
      dd = max_equity > 0 ? ((max_equity - equity) / max_equity * 100) : 0
      max_dd = [max_dd, dd].max
    end

    final_return = starting_capital > 0 ? ((equity - starting_capital) / starting_capital * 100).round(2) : 0
    {
      name: name,
      final_equity: equity.round(2),
      total_return: final_return,
      max_drawdown: max_dd.round(2),
      curve: curve
    }
  end

  def build_anti_martingale(name, trades, starting_capital)
    equity = starting_capital
    curve = [equity]
    max_equity = equity
    max_dd = 0
    base_risk = 0.01
    streak = 0

    trades.each do |t|
      pnl = t["pnl"].to_f

      # Increase risk after consecutive wins
      multiplier = streak > 0 ? [1.0 + streak * 0.25, 3.0].min : 1.0
      risk_amount = equity * base_risk * multiplier
      risk_amount = [risk_amount, equity * 0.5].min

      actual_risk = t["entry_price"].to_f * (t["quantity"] || 1).to_f
      if actual_risk > 0 && risk_amount > 0
        scale = risk_amount / actual_risk
        scaled_pnl = pnl * scale
      else
        scaled_pnl = pnl
      end

      equity += scaled_pnl
      equity = [equity, 0].max
      curve << equity

      max_equity = [max_equity, equity].max
      dd = max_equity > 0 ? ((max_equity - equity) / max_equity * 100) : 0
      max_dd = [max_dd, dd].max

      streak = pnl > 0 ? streak + 1 : 0
    end

    final_return = starting_capital > 0 ? ((equity - starting_capital) / starting_capital * 100).round(2) : 0
    {
      name: name,
      final_equity: equity.round(2),
      total_return: final_return,
      max_drawdown: max_dd.round(2),
      curve: curve
    }
  end
end

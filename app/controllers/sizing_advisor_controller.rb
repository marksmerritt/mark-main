class SizingAdvisorController < ApplicationController
  before_action :require_api_connection

  include ActionView::Helpers::NumberHelper

  def show
    threads = {}
    threads[:trades] = Thread.new { api_client.trades(per_page: 500) rescue {} }
    threads[:stats] = Thread.new { api_client.overview rescue {} }

    trades_result = threads[:trades].value
    @trades = trades_result.is_a?(Hash) ? (trades_result["trades"] || []) : Array(trades_result)
    @trades = @trades.select { |t| t.is_a?(Hash) && t["status"] == "closed" }

    @stats = threads[:stats].value || {}
    @stats = {} unless @stats.is_a?(Hash)

    @account_size = params[:account_size].to_f
    @account_size = 25_000 if @account_size <= 0
    @risk_per_trade = params[:risk_pct].to_f
    @risk_per_trade = 1.0 if @risk_per_trade <= 0

    compute_sizing_models
    compute_by_symbol
    compute_recommendations
  end

  private

  def compute_sizing_models
    return if @trades.empty?

    pnls = @trades.map { |t| t["pnl"].to_f }
    wins = pnls.select(&:positive?)
    losses = pnls.select(&:negative?)

    @win_rate = @trades.any? ? (wins.size.to_f / @trades.size * 100).round(1) : 0
    @avg_win = wins.any? ? (wins.sum / wins.size).round(2) : 0
    @avg_loss = losses.any? ? (losses.sum / losses.size).round(2) : 0
    @expectancy = @trades.any? ? (pnls.sum / @trades.size).round(2) : 0

    # Kelly Criterion
    w = @win_rate / 100.0
    b = @avg_loss != 0 ? (@avg_win / @avg_loss.abs) : 1
    @kelly_full = w > 0 && b > 0 ? ((w * b - (1 - w)) / b * 100).round(2) : 0
    @kelly_half = (@kelly_full / 2).round(2)
    @kelly_quarter = (@kelly_full / 4).round(2)

    # Fixed fractional
    @fixed_risk_amount = (@account_size * @risk_per_trade / 100).round(2)

    # Anti-martingale (scale up after wins)
    @anti_mart_base = @fixed_risk_amount
    @anti_mart_scaled = (@fixed_risk_amount * 1.5).round(2)

    # Optimal F
    max_loss = losses.any? ? losses.min.abs : 1
    @optimal_f = max_loss > 0 ? (@expectancy / max_loss * 100).round(2) : 0
    @optimal_f = [@optimal_f, 25].min # Cap at 25%

    # Volatility-based sizing
    mean = pnls.sum / pnls.size.to_f
    std_dev = Math.sqrt(pnls.sum { |p| (p - mean) ** 2 } / pnls.size.to_f)
    @volatility = std_dev.round(2)
    target_risk = @account_size * @risk_per_trade / 100
    @vol_size = std_dev > 0 ? (target_risk / std_dev).round(2) : 1

    # Models comparison
    @models = [
      {
        name: "Fixed Fractional",
        description: "Risk #{@risk_per_trade}% of account per trade",
        risk_amount: @fixed_risk_amount,
        pct_of_account: @risk_per_trade,
        rating: @risk_per_trade <= 2 ? "conservative" : (@risk_per_trade <= 5 ? "moderate" : "aggressive"),
        icon: "straighten"
      },
      {
        name: "Half Kelly",
        description: "50% of Kelly Criterion — recommended for most traders",
        risk_amount: (@account_size * @kelly_half.abs / 100).round(2),
        pct_of_account: @kelly_half.abs,
        rating: @kelly_half.abs <= 3 ? "conservative" : (@kelly_half.abs <= 8 ? "moderate" : "aggressive"),
        icon: "functions"
      },
      {
        name: "Quarter Kelly",
        description: "25% of Kelly — very conservative growth",
        risk_amount: (@account_size * @kelly_quarter.abs / 100).round(2),
        pct_of_account: @kelly_quarter.abs,
        rating: "conservative",
        icon: "shield"
      },
      {
        name: "Volatility-Based",
        description: "Size based on your P&L standard deviation",
        risk_amount: target_risk,
        pct_of_account: @risk_per_trade,
        units: @vol_size,
        rating: "moderate",
        icon: "show_chart"
      }
    ]

    # Recommended model
    @recommended = if @kelly_half > 0 && @kelly_half < 10
      @models[1] # Half Kelly
    elsif @kelly_half <= 0
      @models[0] # Fixed fractional (Kelly is negative = losing edge)
    else
      @models[2] # Quarter Kelly (Kelly is very high)
    end
  end

  def compute_by_symbol
    @symbol_sizing = {}
    @trades.each do |t|
      sym = t["symbol"]
      next unless sym
      @symbol_sizing[sym] ||= { trades: [], pnl: 0, wins: 0, count: 0 }
      @symbol_sizing[sym][:trades] << t
      @symbol_sizing[sym][:pnl] += t["pnl"].to_f
      @symbol_sizing[sym][:count] += 1
      @symbol_sizing[sym][:wins] += 1 if t["pnl"].to_f > 0
    end

    @symbol_sizing = @symbol_sizing.select { |_, v| v[:count] >= 3 }.map do |sym, data|
      wins = data[:trades].select { |t| t["pnl"].to_f > 0 }
      losses = data[:trades].select { |t| t["pnl"].to_f < 0 }
      avg_win = wins.any? ? wins.sum { |t| t["pnl"].to_f } / wins.size : 0
      avg_loss = losses.any? ? losses.sum { |t| t["pnl"].to_f } / losses.size : 0
      wr = data[:count] > 0 ? (data[:wins].to_f / data[:count]) : 0
      b = avg_loss != 0 ? (avg_win / avg_loss.abs) : 1
      kelly = wr > 0 && b > 0 ? ((wr * b - (1 - wr)) / b * 100).round(2) : 0
      half_kelly = (kelly / 2).round(2)

      {
        symbol: sym,
        count: data[:count],
        win_rate: (wr * 100).round(1),
        pnl: data[:pnl],
        avg_pnl: (data[:pnl] / data[:count]).round(2),
        kelly: kelly,
        half_kelly: half_kelly,
        suggested_risk: [half_kelly.abs, 5].min,
        edge: kelly > 0 ? :positive : :negative
      }
    end.sort_by { |s| -s[:pnl] }
  end

  def compute_recommendations
    @tips = []

    if @kelly_full <= 0
      @tips << { icon: "warning", color: "var(--negative)", text: "Kelly Criterion is negative (#{@kelly_full}%), indicating no statistical edge. Focus on improving win rate or reward:risk ratio before sizing up." }
    elsif @kelly_full > 20
      @tips << { icon: "info", color: "#1976d2", text: "Full Kelly suggests #{@kelly_full}% — this is too aggressive. Use Quarter Kelly (#{@kelly_quarter}%) to protect against ruin." }
    end

    if @risk_per_trade > 3
      @tips << { icon: "shield", color: "#f9a825", text: "Risking more than 3% per trade is aggressive. Most professionals risk 0.5-2% per trade." }
    end

    losing_symbols = @symbol_sizing.select { |s| s[:edge] == :negative }
    if losing_symbols.any?
      names = losing_symbols.first(3).map { |s| s[:symbol] }.join(", ")
      @tips << { icon: "do_not_disturb", color: "var(--negative)", text: "Negative edge on: #{names}. Consider reducing size or stopping these symbols." }
    end

    best = @symbol_sizing.select { |s| s[:edge] == :positive && s[:half_kelly] > 1 }.first
    if best
      @tips << { icon: "trending_up", color: "var(--positive)", text: "#{best[:symbol]} has the strongest edge (#{best[:win_rate]}% WR, Half Kelly #{best[:half_kelly]}%). Consider allocating more risk here." }
    end

    if @volatility > @account_size * 0.03
      @tips << { icon: "flash_on", color: "#ff5722", text: "Your P&L volatility ($#{@volatility}) is high relative to account size. Consider smaller positions." }
    end
  end
end

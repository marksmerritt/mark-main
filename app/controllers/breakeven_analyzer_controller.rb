class BreakevenAnalyzerController < ApplicationController
  before_action :require_api_connection

  include ActionView::Helpers::NumberHelper

  def show
    trade_result = begin
      api_client.trades(per_page: 1000)
    rescue => e
      Rails.logger.error("BreakevenAnalyzer: failed to fetch trades: #{e.message}")
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
      .sort_by { |t| t["exit_time"] || t["entry_time"] || "" }

    return if @trades.empty?

    # === Core metrics ===
    pnls = @trades.map { |t| t["pnl"].to_f }
    wins = @trades.select { |t| t["pnl"].to_f > 0 }
    losses = @trades.select { |t| t["pnl"].to_f < 0 }

    @total_trades = @trades.count
    @win_count = wins.count
    @loss_count = losses.count
    @current_win_rate = @total_trades > 0 ? (wins.count.to_f / @total_trades * 100).round(1) : 0.0
    @avg_win = wins.any? ? (wins.sum { |t| t["pnl"].to_f } / wins.count).round(2) : 0.0
    @avg_loss = losses.any? ? (losses.sum { |t| t["pnl"].to_f.abs } / losses.count).round(2) : 0.0
    @total_pnl = pnls.sum.round(2)
    @avg_pnl = @total_trades > 0 ? (@total_pnl / @total_trades).round(2) : 0.0

    # === Total costs (fees + commissions) ===
    @total_fees = @trades.sum { |t| t["fees"].to_f }.round(2)
    @total_commissions = @trades.sum { |t| t["commission"].to_f }.round(2)
    @total_costs = (@total_fees + @total_commissions).round(2)
    @gross_pnl = (@total_pnl + @total_costs).round(2)
    @avg_cost_per_trade = @total_trades > 0 ? (@total_costs / @total_trades).round(2) : 0.0

    # === Slippage estimate (0.05% of notional per trade) ===
    @estimated_slippage = @trades.sum { |t|
      entry = t["entry_price"].to_f
      qty = t["quantity"].to_f
      notional = entry * qty
      notional > 0 ? notional * 0.0005 : 0.0
    }.round(2)
    @all_in_costs = (@total_costs + @estimated_slippage).round(2)

    # === Breakeven Win Rate ===
    # At current avg win/loss sizes, what win rate is needed to break even?
    # breakeven WR = avg_loss / (avg_win + avg_loss)
    if @avg_win > 0 && @avg_loss > 0
      @breakeven_win_rate = (@avg_loss / (@avg_win + @avg_loss) * 100).round(1)
    else
      @breakeven_win_rate = 0.0
    end

    # === Breakeven R:R ===
    # At current win rate, what minimum R:R (avg_win / avg_loss) is needed?
    # breakeven R:R = (1 - WR) / WR
    if @current_win_rate > 0 && @current_win_rate < 100
      wr_decimal = @current_win_rate / 100.0
      @breakeven_rr = ((1.0 - wr_decimal) / wr_decimal).round(2)
    else
      @breakeven_rr = 0.0
    end

    # Current R:R
    @current_rr = @avg_loss > 0 ? (@avg_win / @avg_loss).round(2) : 0.0

    # === Margin of Safety ===
    # How far above breakeven win rate is the trader?
    @margin_of_safety_wr = (@current_win_rate - @breakeven_win_rate).round(1)
    @margin_of_safety_rr = (@current_rr - @breakeven_rr).round(2)
    @margin_of_safety_label = if @margin_of_safety_wr > 15
                                "Strong"
                              elsif @margin_of_safety_wr > 5
                                "Moderate"
                              elsif @margin_of_safety_wr > 0
                                "Thin"
                              else
                                "Underwater"
                              end

    # === Commission Breakeven ===
    # How many profitable trades at avg win size to cover total commissions?
    @commission_breakeven_trades = if @avg_win > 0 && @total_costs > 0
                                     (@total_costs / @avg_win).ceil
                                   else
                                     0
                                   end

    # === Cost Ratio ===
    @cost_ratio = @gross_pnl.abs > 0 ? (@all_in_costs / @gross_pnl.abs * 100).round(1) : 0.0

    # === Monthly Breakeven ===
    compute_monthly_breakeven

    # === Per-Symbol Breakeven ===
    compute_per_symbol_breakeven

    # === Trades to Profitability ===
    compute_trades_to_profitability

    # === Breakeven Position Size ===
    compute_breakeven_position_size

    # === What-If Breakeven Scenarios ===
    compute_what_if_scenarios

    # === Win Rate Sensitivity Table ===
    compute_win_rate_sensitivity
  end

  private

  def compute_monthly_breakeven
    monthly = {}
    @trades.each do |t|
      month = (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 7)
      next unless month
      monthly[month] ||= { pnl: 0, fees: 0, commissions: 0, trades: 0 }
      monthly[month][:pnl] += t["pnl"].to_f
      monthly[month][:fees] += t["fees"].to_f
      monthly[month][:commissions] += t["commission"].to_f
      monthly[month][:trades] += 1
    end

    @monthly_data = monthly.sort_by { |k, _| k }.to_h
    months_count = [monthly.count, 1].max
    @avg_monthly_costs = ((monthly.values.sum { |v| v[:fees] + v[:commissions] }) / months_count).round(2)
    @avg_monthly_pnl = (monthly.values.sum { |v| v[:pnl] } / months_count).round(2)
    @avg_monthly_trades = (monthly.values.sum { |v| v[:trades] }.to_f / months_count).round(1)

    # Monthly breakeven: how many avg-expectancy trades per month to cover costs
    @monthly_breakeven_trades = if @avg_pnl > 0 && @avg_monthly_costs > 0
                                   (@avg_monthly_costs / @avg_pnl).ceil
                                 else
                                   nil
                                 end
  end

  def compute_per_symbol_breakeven
    symbol_groups = @trades.group_by { |t| (t["symbol"] || "Unknown").upcase }
    @symbol_breakeven = []

    symbol_groups.each do |symbol, trades|
      next if trades.count < 2

      sym_wins = trades.select { |t| t["pnl"].to_f > 0 }
      sym_losses = trades.select { |t| t["pnl"].to_f < 0 }
      sym_win_rate = trades.any? ? (sym_wins.count.to_f / trades.count * 100).round(1) : 0.0
      sym_avg_win = sym_wins.any? ? (sym_wins.sum { |t| t["pnl"].to_f } / sym_wins.count).round(2) : 0.0
      sym_avg_loss = sym_losses.any? ? (sym_losses.sum { |t| t["pnl"].to_f.abs } / sym_losses.count).round(2) : 0.0
      sym_total_pnl = trades.sum { |t| t["pnl"].to_f }.round(2)
      sym_fees = trades.sum { |t| t["fees"].to_f + t["commission"].to_f }.round(2)

      sym_be_wr = if sym_avg_win > 0 && sym_avg_loss > 0
                    (sym_avg_loss / (sym_avg_win + sym_avg_loss) * 100).round(1)
                  else
                    0.0
                  end

      sym_margin = (sym_win_rate - sym_be_wr).round(1)

      @symbol_breakeven << {
        symbol: symbol,
        trades: trades.count,
        win_rate: sym_win_rate,
        breakeven_wr: sym_be_wr,
        margin: sym_margin,
        avg_win: sym_avg_win,
        avg_loss: sym_avg_loss,
        total_pnl: sym_total_pnl,
        fees: sym_fees,
        profitable: sym_margin > 0
      }
    end

    @symbol_breakeven.sort_by! { |s| -s[:margin] }
  end

  def compute_trades_to_profitability
    # From zero, how many average-expectancy trades to cover max drawdown?
    cumulative = 0.0
    peak = 0.0
    max_dd = 0.0

    @trades.each do |t|
      cumulative += t["pnl"].to_f
      peak = cumulative if cumulative > peak
      dd = peak - cumulative
      max_dd = dd if dd > max_dd
    end

    @max_drawdown = max_dd.round(2)
    @trades_to_recover_dd = if @avg_pnl > 0 && @max_drawdown > 0
                               (@max_drawdown / @avg_pnl).ceil
                             else
                               nil
                             end

    # From zero, how many trades to cover all accumulated costs?
    @trades_to_cover_costs = if @avg_pnl > 0 && @all_in_costs > 0
                                (@all_in_costs / @avg_pnl).ceil
                              else
                                nil
                              end
  end

  def compute_breakeven_position_size
    # Minimum position size to make trading worthwhile after fees
    # Given avg cost per trade, what position size yields at least that much expected profit?
    # Expected profit per share = WR * avg_win_per_share - (1-WR) * avg_loss_per_share
    # We need expected profit * qty > avg_cost_per_trade

    avg_entry = @trades.any? ? (@trades.sum { |t| t["entry_price"].to_f } / @trades.count) : 0
    avg_qty = @trades.any? ? (@trades.sum { |t| t["quantity"].to_f } / @trades.count) : 0

    if avg_entry > 0 && avg_qty > 0 && @avg_pnl > 0
      avg_pnl_per_share = @avg_pnl / [avg_qty, 1].max
      # min shares needed = cost_per_trade / pnl_per_share
      @min_shares = avg_pnl_per_share > 0 ? (@avg_cost_per_trade / avg_pnl_per_share).ceil : nil
      @min_notional = @min_shares && avg_entry > 0 ? (@min_shares * avg_entry).round(0) : nil
    else
      @min_shares = nil
      @min_notional = nil
    end

    @avg_position_size = (avg_entry * avg_qty).round(0) if avg_entry > 0 && avg_qty > 0
  end

  def compute_what_if_scenarios
    @what_if_scenarios = []

    # What if win rate drops by 5/10/15/20/25/30%?
    [5, 10, 15, 20, 25, 30].each do |drop|
      adjusted_wr = @current_win_rate - drop
      next if adjusted_wr <= 0

      wr_decimal = adjusted_wr / 100.0
      # Expected P&L per trade = WR * avg_win - (1-WR) * avg_loss
      expected_pnl = (wr_decimal * @avg_win - (1.0 - wr_decimal) * @avg_loss).round(2)
      # Expected over same number of trades
      total_expected = (expected_pnl * @total_trades).round(2)
      profitable = expected_pnl > 0

      @what_if_scenarios << {
        label: "-#{drop}% WR",
        win_rate: adjusted_wr.round(1),
        expected_pnl_per_trade: expected_pnl,
        total_expected: total_expected,
        profitable: profitable,
        margin_vs_breakeven: (adjusted_wr - @breakeven_win_rate).round(1)
      }
    end
  end

  def compute_win_rate_sensitivity
    @sensitivity_rows = []

    # From 20% to 80% win rate in 5% steps
    (20..80).step(5).each do |wr_pct|
      wr_decimal = wr_pct / 100.0
      expected_pnl = (wr_decimal * @avg_win - (1.0 - wr_decimal) * @avg_loss).round(2)
      # Net of avg cost per trade
      net_pnl = (expected_pnl - @avg_cost_per_trade).round(2)
      monthly_est = (net_pnl * @avg_monthly_trades).round(2) if @avg_monthly_trades > 0

      @sensitivity_rows << {
        win_rate: wr_pct,
        gross_per_trade: expected_pnl,
        net_per_trade: net_pnl,
        monthly_est: monthly_est || 0.0,
        is_current: (wr_pct - @current_win_rate).abs < 2.5,
        is_breakeven: (wr_pct - @breakeven_win_rate).abs < 2.5,
        profitable: net_pnl > 0
      }
    end
  end
end

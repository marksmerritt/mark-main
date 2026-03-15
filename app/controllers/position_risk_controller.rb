class PositionRiskController < ApplicationController
  before_action :require_api_connection

  def show
    result = api_client.trades(per_page: 500)
    all_trades = result.is_a?(Hash) ? (result["trades"] || []) : Array(result)

    @open_trades = all_trades.select { |t| t["status"] == "open" }
    @closed_trades = all_trades.select { |t| t["status"] != "open" }

    compute_exposure
    compute_direction_exposure
    compute_position_sizing
    compute_correlation_risk
    compute_risk_per_trade
    compute_portfolio_heat
    compute_drawdown
    compute_var
    compute_alerts
  end

  private

  def compute_exposure
    @gross_exposure = @open_trades.sum { |t| t["entry_price"].to_f * t["quantity"].to_i }

    @by_symbol = {}
    @open_trades.each do |t|
      sym = t["symbol"] || "Unknown"
      exposure = t["entry_price"].to_f * t["quantity"].to_i
      @by_symbol[sym] ||= { exposure: 0, trades: 0 }
      @by_symbol[sym][:exposure] += exposure
      @by_symbol[sym][:trades] += 1
    end
    @by_symbol.each do |_, d|
      d[:pct] = @gross_exposure > 0 ? (d[:exposure] / @gross_exposure * 100).round(1) : 0
    end
    @by_symbol = @by_symbol.sort_by { |_, d| -d[:exposure] }.to_h

    @concentrated_symbols = @by_symbol.select { |_, d| d[:pct] > 20 }
  end

  def compute_direction_exposure
    @long_trades = @open_trades.select { |t| t["side"] == "long" }
    @short_trades = @open_trades.select { |t| t["side"] == "short" }

    @long_exposure = @long_trades.sum { |t| t["entry_price"].to_f * t["quantity"].to_i }
    @short_exposure = @short_trades.sum { |t| t["entry_price"].to_f * t["quantity"].to_i }
    @net_exposure = @long_exposure - @short_exposure

    @long_pct = @gross_exposure > 0 ? (@long_exposure / @gross_exposure * 100).round(1) : 0
    @short_pct = @gross_exposure > 0 ? (@short_exposure / @gross_exposure * 100).round(1) : 0
  end

  def compute_position_sizing
    exposures = @open_trades.map { |t| t["entry_price"].to_f * t["quantity"].to_i }
    @largest_position = exposures.max || 0
    @smallest_position = exposures.select { |e| e > 0 }.min || 0
    @avg_position = exposures.any? ? (exposures.sum / exposures.count.to_f).round(2) : 0

    # Coefficient of variation
    if exposures.count > 1 && @avg_position > 0
      variance = exposures.sum { |e| (e - @avg_position) ** 2 } / exposures.count.to_f
      std_dev = Math.sqrt(variance)
      @position_cv = (std_dev / @avg_position * 100).round(1)
    else
      @position_cv = 0
    end
  end

  def compute_correlation_risk
    # Find symbols with overlapping open dates
    @correlated_pairs = []
    symbols_with_dates = {}

    @open_trades.each do |t|
      sym = t["symbol"] || "Unknown"
      entry_date = (t["entry_time"] || t["created_at"])&.to_s&.slice(0, 10)
      symbols_with_dates[sym] ||= []
      symbols_with_dates[sym] << entry_date
    end

    syms = symbols_with_dates.keys
    syms.each_with_index do |s1, i|
      syms[(i + 1)..].each do |s2|
        next if s1 == s2
        dates1 = symbols_with_dates[s1]
        dates2 = symbols_with_dates[s2]
        # Check if any entries are within 2 days of each other
        overlap = dates1.any? { |d1|
          dates2.any? { |d2|
            next false unless d1 && d2
            (Date.parse(d1) - Date.parse(d2)).abs <= 2 rescue false
          }
        }
        @correlated_pairs << [s1, s2] if overlap
      end
    end
  end

  def compute_risk_per_trade
    @position_risks = @open_trades.map { |t|
      entry = t["entry_price"].to_f
      stop = t["stop_loss"]&.to_f
      qty = t["quantity"].to_i
      exposure = entry * qty
      pct_of_portfolio = @gross_exposure > 0 ? (exposure / @gross_exposure * 100).round(1) : 0

      risk_amount = if stop && stop > 0 && entry > 0 && qty > 0
        (entry - stop).abs * qty
      else
        nil
      end

      {
        id: t["id"],
        symbol: t["symbol"],
        side: t["side"],
        entry: entry,
        quantity: qty,
        exposure: exposure,
        stop: stop,
        risk_amount: risk_amount,
        has_stop: stop.to_f > 0,
        pct_of_portfolio: pct_of_portfolio,
        pnl: t["pnl"].to_f,
        entry_time: (t["entry_time"] || t["created_at"])&.to_s&.slice(0, 10)
      }
    }.sort_by { |p| -(p[:exposure]) }

    @no_stop_trades = @position_risks.select { |p| !p[:has_stop] }
  end

  def compute_portfolio_heat
    @total_risk_at_stop = @position_risks.sum { |p| p[:risk_amount] || 0 }
    @portfolio_heat = if @gross_exposure > 0
      (@total_risk_at_stop / @gross_exposure * 100).round(1)
    else
      0
    end
  end

  def compute_drawdown
    sorted_closed = @closed_trades.sort_by { |t| t["exit_time"] || t["entry_time"] || "" }

    running = 0
    peak = 0
    @equity_curve = []

    sorted_closed.each do |t|
      running += t["pnl"].to_f
      peak = [peak, running].max
      dd = peak > 0 ? ((peak - running) / peak * 100).round(2) : 0
      @equity_curve << {
        date: (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 10),
        equity: running.round(2),
        peak: peak.round(2),
        drawdown_pct: dd
      }
    end

    @max_drawdown = @equity_curve.map { |d| d[:drawdown_pct] }.max || 0
    @current_drawdown = @equity_curve.last&.dig(:drawdown_pct) || 0
    @current_equity = @equity_curve.last&.dig(:equity) || 0
    @equity_peak = @equity_curve.map { |d| d[:peak] }.max || 0
  end

  def compute_var
    # Simple historical VaR from recent P&L distribution (95th percentile)
    pnls = @closed_trades.map { |t| t["pnl"].to_f }.sort

    if pnls.count >= 5
      idx = (pnls.count * 0.05).floor
      @var_95 = pnls[idx]&.round(2) || 0
      @var_avg_loss = pnls.select { |p| p < 0 }.then { |losses|
        losses.any? ? (losses.sum / losses.count.to_f).round(2) : 0
      }
      @var_worst = pnls.first || 0
      @var_count = pnls.count
    else
      @var_95 = 0
      @var_avg_loss = 0
      @var_worst = 0
      @var_count = pnls.count
    end
  end

  def compute_alerts
    @risk_alerts = []

    # Concentration alerts
    @concentrated_symbols.each do |sym, data|
      @risk_alerts << {
        severity: "warning",
        icon: "pie_chart",
        title: "High Concentration: #{sym}",
        message: "#{sym} represents #{data[:pct]}% of your portfolio (threshold: 20%). Consider reducing exposure."
      }
    end

    # Missing stop losses
    if @no_stop_trades.any?
      symbols = @no_stop_trades.map { |p| p[:symbol] }.uniq.join(", ")
      @risk_alerts << {
        severity: "danger",
        icon: "gpp_bad",
        title: "Missing Stop Losses",
        message: "#{@no_stop_trades.count} position#{'s' if @no_stop_trades.count != 1} without stop losses: #{symbols}. Undefined risk."
      }
    end

    # High portfolio heat
    if @portfolio_heat > 10
      @risk_alerts << {
        severity: "danger",
        icon: "local_fire_department",
        title: "High Portfolio Heat",
        message: "Portfolio heat is #{@portfolio_heat}% (risk at stop / total exposure). Consider reducing position sizes."
      }
    elsif @portfolio_heat > 5
      @risk_alerts << {
        severity: "warning",
        icon: "local_fire_department",
        title: "Elevated Portfolio Heat",
        message: "Portfolio heat is #{@portfolio_heat}%. Monitor closely."
      }
    end

    # Drawdown alert
    if @max_drawdown > 15
      @risk_alerts << {
        severity: "danger",
        icon: "trending_down",
        title: "Significant Drawdown",
        message: "Max drawdown reached #{@max_drawdown}%. Current drawdown: #{@current_drawdown}%."
      }
    elsif @current_drawdown > 5
      @risk_alerts << {
        severity: "warning",
        icon: "trending_down",
        title: "Active Drawdown",
        message: "Currently in a #{@current_drawdown}% drawdown from equity peak."
      }
    end

    # Direction imbalance
    if @long_pct > 85 && @open_trades.count >= 3
      @risk_alerts << {
        severity: "warning",
        icon: "swap_vert",
        title: "Directional Bias: Heavily Long",
        message: "#{@long_pct}% long exposure. Consider hedging or adding short positions."
      }
    elsif @short_pct > 85 && @open_trades.count >= 3
      @risk_alerts << {
        severity: "warning",
        icon: "swap_vert",
        title: "Directional Bias: Heavily Short",
        message: "#{@short_pct}% short exposure. High directional risk."
      }
    end

    # Correlated positions
    if @correlated_pairs.count >= 3
      @risk_alerts << {
        severity: "warning",
        icon: "hub",
        title: "Correlated Entries",
        message: "#{@correlated_pairs.count} symbol pairs entered within 2 days. Positions may move together."
      }
    end

    # Negative VaR
    if @var_95 < -500
      @risk_alerts << {
        severity: "warning",
        icon: "functions",
        title: "High Value at Risk",
        message: "95% VaR is #{number_to_currency(@var_95)}. 5% chance of losing more than this per trade."
      }
    end
  end

  def number_to_currency(val)
    ActionController::Base.helpers.number_to_currency(val)
  end
end

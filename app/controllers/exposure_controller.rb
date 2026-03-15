class ExposureController < ApplicationController
  before_action :require_api_connection

  def index
    result = api_client.trades(status: "open", per_page: 200)
    trades = result.is_a?(Hash) ? (result["trades"] || []) : (result || [])

    @open_trades = trades
    @total_positions = trades.count

    # Position values
    @long_trades = trades.select { |t| t["side"] == "long" }
    @short_trades = trades.select { |t| t["side"] == "short" }

    @long_exposure = @long_trades.sum { |t| t["entry_price"].to_f * t["quantity"].to_i }
    @short_exposure = @short_trades.sum { |t| t["entry_price"].to_f * t["quantity"].to_i }
    @gross_exposure = @long_exposure + @short_exposure
    @net_exposure = @long_exposure - @short_exposure

    # Unrealized P&L
    @unrealized_pnl = trades.sum { |t| t["pnl"].to_f }

    # By symbol concentration
    @by_symbol = {}
    trades.each do |t|
      sym = t["symbol"] || "Unknown"
      @by_symbol[sym] ||= { trades: 0, exposure: 0, pnl: 0, side: t["side"], asset_class: t["asset_class"] }
      @by_symbol[sym][:trades] += 1
      @by_symbol[sym][:exposure] += t["entry_price"].to_f * t["quantity"].to_i
      @by_symbol[sym][:pnl] += t["pnl"].to_f
    end
    @by_symbol.each do |_, d|
      d[:pct] = @gross_exposure > 0 ? (d[:exposure] / @gross_exposure * 100).round(1) : 0
    end
    @by_symbol = @by_symbol.sort_by { |_, d| -d[:exposure] }.to_h

    # By asset class
    @by_asset_class = {}
    trades.each do |t|
      ac = t["asset_class"].presence || "Unknown"
      @by_asset_class[ac] ||= { trades: 0, exposure: 0, pnl: 0 }
      @by_asset_class[ac][:trades] += 1
      @by_asset_class[ac][:exposure] += t["entry_price"].to_f * t["quantity"].to_i
      @by_asset_class[ac][:pnl] += t["pnl"].to_f
    end
    @by_asset_class.each do |_, d|
      d[:pct] = @gross_exposure > 0 ? (d[:exposure] / @gross_exposure * 100).round(1) : 0
    end

    # By side
    @long_pct = @gross_exposure > 0 ? (@long_exposure / @gross_exposure * 100).round(1) : 0
    @short_pct = @gross_exposure > 0 ? (@short_exposure / @gross_exposure * 100).round(1) : 0

    # Risk at stop
    @total_risk_at_stop = 0
    trades.each do |t|
      stop = t["stop_loss"]&.to_f
      entry = t["entry_price"].to_f
      qty = t["quantity"].to_i
      if stop && stop > 0 && entry > 0 && qty > 0
        @total_risk_at_stop += (entry - stop).abs * qty
      end
    end

    # Concentration score (HHI-based)
    if @by_symbol.any?
      shares = @by_symbol.values.map { |d| d[:pct] / 100.0 }
      @hhi = (shares.sum { |s| s ** 2 } * 10_000).round(0)
      @concentration = if @hhi > 5000 then "High"
                       elsif @hhi > 2500 then "Moderate"
                       else "Diversified"
                       end
      @concentration_color = case @concentration
                             when "High" then "var(--negative)"
                             when "Moderate" then "#f9ab00"
                             else "var(--positive)"
                             end
    end
  end
end

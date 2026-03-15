class TradingCostsController < ApplicationController
  before_action :require_api_connection

  include ActionView::Helpers::NumberHelper

  def show
    result = api_client.trades(per_page: 5000, status: "closed")
    @trades = result.is_a?(Hash) ? (result["trades"] || []) : Array(result)
    @trades = @trades.select { |t| t.is_a?(Hash) }

    return if @trades.empty?

    # Overall fee metrics
    @total_fees = @trades.sum { |t| t["fees"].to_f }
    @total_pnl = @trades.sum { |t| t["pnl"].to_f }
    @gross_pnl = @total_pnl + @total_fees
    @avg_fee = @trades.any? ? (@total_fees / @trades.count).round(2) : 0
    @fee_impact_pct = @gross_pnl != 0 ? (@total_fees / @gross_pnl.abs * 100).round(1) : 0

    # Trades where fees exceeded profit
    @fee_exceeded = @trades.select { |t|
      pnl = t["pnl"].to_f
      fees = t["fees"].to_f
      pnl > 0 && fees > 0 && fees > pnl
    }

    # Trades turned losing by fees
    @flipped_by_fees = @trades.select { |t|
      pnl = t["pnl"].to_f
      fees = t["fees"].to_f
      pnl < 0 && (pnl + fees) > 0
    }

    # Monthly fee analysis
    @monthly_fees = {}
    @trades.each do |t|
      month = (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 7)
      next unless month
      @monthly_fees[month] ||= { fees: 0, trades: 0, pnl: 0, gross: 0 }
      @monthly_fees[month][:fees] += t["fees"].to_f
      @monthly_fees[month][:trades] += 1
      @monthly_fees[month][:pnl] += t["pnl"].to_f
      @monthly_fees[month][:gross] += t["pnl"].to_f + t["fees"].to_f
    end

    # Fee by asset class
    @by_asset = {}
    @trades.each do |t|
      asset = t["asset_class"]&.capitalize || "Unknown"
      @by_asset[asset] ||= { fees: 0, trades: 0, avg_fee: 0 }
      @by_asset[asset][:fees] += t["fees"].to_f
      @by_asset[asset][:trades] += 1
    end
    @by_asset.each { |_, v| v[:avg_fee] = (v[:fees] / [v[:trades], 1].max).round(2) }
    @by_asset = @by_asset.sort_by { |_, v| -v[:fees] }.to_h

    # Fee by symbol
    @by_symbol = {}
    @trades.each do |t|
      sym = t["symbol"] || "Unknown"
      @by_symbol[sym] ||= { fees: 0, trades: 0, pnl: 0 }
      @by_symbol[sym][:fees] += t["fees"].to_f
      @by_symbol[sym][:trades] += 1
      @by_symbol[sym][:pnl] += t["pnl"].to_f
    end
    @by_symbol = @by_symbol.sort_by { |_, v| -v[:fees] }.first(15).to_h

    # Slippage analysis (if MFE/MAE available)
    trades_with_mfe = @trades.select { |t| t["mfe"].to_f > 0 }
    if trades_with_mfe.any?
      @avg_capture = trades_with_mfe.map { |t|
        mfe = t["mfe"].to_f
        pnl = t["pnl"].to_f
        mfe > 0 ? (pnl / mfe * 100).round(1) : 0
      }
      @avg_capture_pct = (@avg_capture.sum / @avg_capture.count).round(1)
      @left_on_table = trades_with_mfe.sum { |t| t["mfe"].to_f - t["pnl"].to_f }
    end

    # Fee efficiency: what if fees were 50% less?
    @half_fee_pnl = @trades.sum { |t| t["pnl"].to_f + t["fees"].to_f * 0.5 }
    @zero_fee_pnl = @gross_pnl
    @fee_savings_opportunity = @total_fees * 0.5
  end
end

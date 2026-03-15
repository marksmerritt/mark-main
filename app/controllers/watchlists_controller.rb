class WatchlistsController < ApplicationController
  before_action :require_api_connection

  def index
    filter_params = params.permit(:active, :priority, :page).to_h.compact_blank
    threads = {}
    threads[:watchlists] = Thread.new { api_client.watchlists(filter_params) }
    threads[:trades] = Thread.new { api_client.trades(status: "closed", per_page: 500) }

    result = threads[:watchlists].value
    @watchlists = result["watchlists"] || result
    @meta = result["meta"] || {}

    trade_result = threads[:trades].value
    trades = trade_result.is_a?(Hash) ? (trade_result["trades"] || []) : (trade_result || [])

    @symbol_history = {}
    if @watchlists.is_a?(Array)
      @watchlists.each do |w|
        sym = w["symbol"]&.upcase
        next unless sym
        matching = trades.select { |t| t["symbol"]&.upcase == sym }
        next if matching.empty?
        wins = matching.count { |t| t["pnl"].to_f > 0 }
        total_pnl = matching.sum { |t| t["pnl"].to_f }
        @symbol_history[sym] = {
          trades: matching.count,
          wins: wins,
          win_rate: (wins.to_f / matching.count * 100).round(0),
          total_pnl: total_pnl.round(2),
          last_trade: matching.max_by { |t| t["entry_time"].to_s }
        }
      end
    end
  end

  def show
    @watchlist = api_client.watchlist(params[:id])
  end

  def new
    @watchlist = {}
  end

  def create
    result = api_client.create_watchlist(watchlist_params)
    if result["id"]
      redirect_to watchlist_path(result["id"]), notice: "Watchlist item created successfully."
    else
      @watchlist = watchlist_params
      @errors = result["errors"] || [result["message"]]
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @watchlist = api_client.watchlist(params[:id])
  end

  def update
    result = api_client.update_watchlist(params[:id], watchlist_params)
    if result["id"]
      redirect_to watchlist_path(result["id"]), notice: "Watchlist item updated successfully."
    else
      @watchlist = api_client.watchlist(params[:id])
      @errors = result["errors"] || [result["message"]]
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    api_client.delete_watchlist(params[:id])
    redirect_to watchlists_path, notice: "Watchlist item deleted successfully."
  end

  private

  def watchlist_params
    params.require(:watchlist).permit(
      :symbol, :asset_class, :notes, :target_entry, :alert_above,
      :alert_below, :priority, :active
    ).to_h.compact_blank
  end
end

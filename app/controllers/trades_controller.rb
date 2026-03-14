class TradesController < ApplicationController
  before_action :require_api_connection

  def index
    filter_params = params.permit(:symbol, :asset_class, :status, :side, :tag_id, :start_date, :end_date).to_h.compact_blank
    @trades = api_client.trades(filter_params)
    @tags = cached_tags
  end

  def show
    @trade = api_client.trade(params[:id])
  end

  def new
    @trade = {}
    @tags = cached_tags
  end

  def create
    result = api_client.create_trade(trade_params.merge(tag_ids: params[:tag_ids]))
    if result["id"]
      redirect_to trade_path(result["id"]), notice: "Trade created successfully."
    else
      @trade = trade_params
      @tags = cached_tags
      @errors = result["errors"] || [result["message"]]
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @trade = api_client.trade(params[:id])
    @tags = cached_tags
  end

  def update
    result = api_client.update_trade(params[:id], trade_params.merge(tag_ids: params[:tag_ids]))
    if result["id"]
      redirect_to trade_path(result["id"]), notice: "Trade updated successfully."
    else
      @trade = api_client.trade(params[:id])
      @tags = cached_tags
      @errors = result["errors"] || [result["message"]]
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    api_client.delete_trade(params[:id])
    redirect_to trades_path, notice: "Trade deleted successfully."
  end

  private

  def trade_params
    params.require(:trade).permit(
      :symbol, :asset_class, :side, :quantity, :entry_price, :exit_price,
      :entry_time, :exit_time, :commissions, :fees, :notes, :setup,
      :mistakes, :lessons, :max_favorable_excursion, :max_adverse_excursion
    ).to_h.compact_blank
  end
end

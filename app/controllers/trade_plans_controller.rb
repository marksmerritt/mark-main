class TradePlansController < ApplicationController
  before_action :require_api_connection

  def index
    filter_params = params.permit(:status, :page).to_h.compact_blank
    threads = {}
    threads[:plans] = Thread.new { api_client.trade_plans(filter_params) }
    threads[:trades] = Thread.new {
      api_client.trades(per_page: 500, status: "closed")
    }

    result = threads[:plans].value
    @trade_plans = result["trade_plans"] || result
    @meta = result["meta"] || {}

    trades_result = threads[:trades].value
    all_trades = trades_result.is_a?(Hash) ? (trades_result["trades"] || []) : (trades_result || [])

    # Compute stats for chips
    if @trade_plans.is_a?(Array)
      @total_plans = @trade_plans.count
      @active_plans = @trade_plans.count { |p| p["status"] == "planned" || p["status"] == "active" }
      @plans_with_matches = @trade_plans.count do |plan|
        plan_symbol = plan["symbol"]&.upcase
        plan_side = plan["side"]&.downcase
        plan_created = plan["created_at"]
        next false unless plan_symbol && plan_created

        all_trades.any? do |t|
          t["symbol"]&.upcase == plan_symbol &&
            (plan_side.blank? || t["side"]&.downcase == plan_side) &&
            t["entry_time"].to_s >= plan_created.to_s
        end
      end
    else
      @total_plans = 0
      @active_plans = 0
      @plans_with_matches = 0
    end
  end

  def show
    @trade_plan = api_client.trade_plan(params[:id])

    # Fetch trades that match this plan's symbol and side, entered after plan creation
    plan_symbol = @trade_plan["symbol"]&.upcase
    plan_created = @trade_plan["created_at"]
    plan_side = @trade_plan["side"]&.downcase

    if plan_symbol.present? && plan_created.present?
      result = api_client.trades(symbol: plan_symbol, per_page: 100, status: "closed")
      all_trades = result.is_a?(Hash) ? (result["trades"] || []) : (result || [])

      @matched_trades = all_trades.select do |t|
        t["entry_time"].to_s >= plan_created.to_s &&
          (plan_side.blank? || t["side"]&.downcase == plan_side)
      end.first(20)

      # Count total trades after plan creation for execution rate
      all_result = api_client.trades(per_page: 100, status: "closed")
      all_closed = all_result.is_a?(Hash) ? (all_result["trades"] || []) : (all_result || [])
      @total_trades_after_plan = all_closed.count { |t| t["entry_time"].to_s >= plan_created.to_s }
    else
      @matched_trades = []
      @total_trades_after_plan = 0
    end
  end

  def new
    @trade_plan = {}
  end

  def create
    result = api_client.create_trade_plan(trade_plan_params)
    if result["id"]
      redirect_to trade_plan_path(result["id"]), notice: "Trade plan created successfully."
    else
      @trade_plan = trade_plan_params
      @errors = result["errors"] || [result["message"]]
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @trade_plan = api_client.trade_plan(params[:id])
  end

  def update
    result = api_client.update_trade_plan(params[:id], trade_plan_params)
    if result["id"]
      redirect_to trade_plan_path(result["id"]), notice: "Trade plan updated successfully."
    else
      @trade_plan = api_client.trade_plan(params[:id])
      @errors = result["errors"] || [result["message"]]
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    api_client.delete_trade_plan(params[:id])
    redirect_to trade_plans_path, notice: "Trade plan deleted successfully."
  end

  def execute
    result = api_client.execute_trade_plan(params[:id], entry_price: params[:entry_price])
    if result["id"]
      redirect_to trade_path(result["id"]), notice: "Trade plan executed. Trade created."
    else
      redirect_to trade_plan_path(params[:id]), alert: result["message"] || "Failed to execute trade plan."
    end
  end

  private

  def trade_plan_params
    params.require(:trade_plan).permit(
      :symbol, :side, :asset_class, :entry_trigger, :exit_strategy,
      :target_entry, :stop_loss, :take_profit, :position_size, :notes, :status
    ).to_h.compact_blank
  end
end

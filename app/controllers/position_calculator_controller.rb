class PositionCalculatorController < ApplicationController
  before_action :require_api_connection

  def index
    @result = nil
    load_risk_profile
  end

  def calculate
    @result = api_client.calculate_position(calculator_params)

    if @result["error"]
      @errors = [@result["message"]].flatten
      @result = nil
    end

    load_risk_profile
    render :index
  end

  private

  def calculator_params
    params.permit(
      :account_size, :risk_percent, :entry_price,
      :stop_loss, :take_profit, :commission_per_share
    ).to_h.compact_blank
  end

  def load_risk_profile
    @risk_profile = api_client.risk_analysis rescue nil
    @stats = api_client.overview rescue nil
  end
end

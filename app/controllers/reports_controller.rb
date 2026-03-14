class ReportsController < ApplicationController
  before_action :require_api_connection

  def overview
    filter_params = params.permit(:start_date, :end_date).to_h.compact_blank
    @stats = api_client.overview(filter_params)
  end

  def by_symbol
    filter_params = params.permit(:start_date, :end_date).to_h.compact_blank
    @symbols = api_client.report_by_symbol(filter_params)
  end

  def equity_curve
    filter_params = params.permit(:start_date, :end_date).to_h.compact_blank
    @equity_data = api_client.equity_curve(filter_params)
  end
end

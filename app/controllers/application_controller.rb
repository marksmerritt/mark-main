class ApplicationController < ActionController::Base
  allow_browser versions: :modern

  private

  def api_client
    @api_client ||= TradingJournalClient.new(api_token)
  end

  def api_token
    ENV["TRADING_JOURNAL_TOKEN"]
  end

  def require_api_connection
    unless api_token.present?
      redirect_to root_path, alert: "Trading Journal is not connected. Set TRADING_JOURNAL_TOKEN."
    end
  end

  helper_method :api_token
end

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
    redirect_to root_path, alert: "Trading Journal is not connected." unless api_token.present?
  end

  def cached_tags
    @cached_tags ||= api_client.tags
  end

  helper_method :api_token, :cached_tags
end

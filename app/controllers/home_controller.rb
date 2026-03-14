class HomeController < ApplicationController
  def index
    if api_token.present?
      client = TradingJournalClient.new(api_token)
      @stats = client.overview
      @recent_trades = client.trades
      @tags = client.tags
    end
  end

  private

  def api_token
    ENV["TRADING_JOURNAL_TOKEN"]
  end
end

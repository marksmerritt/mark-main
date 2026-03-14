class HomeController < ApplicationController
  def index
    if api_token.present?
      @stats = api_client.overview
      @recent_trades = api_client.trades
      @tags = api_client.tags
    end
  end
end

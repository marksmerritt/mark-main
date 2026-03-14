class HomeController < ApplicationController
  def index
    if api_token.present?
      @stats = api_client.overview
      result = api_client.trades(per_page: 10)
      @recent_trades = result["trades"] || result
      @tags = cached_tags
    end
  end
end

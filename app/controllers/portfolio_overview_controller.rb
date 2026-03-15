class PortfolioOverviewController < ApplicationController
  include ActionView::Helpers::NumberHelper

  def show
    threads = {}

    # Trading API calls
    if api_token.present?
      threads[:trading_overview] = Thread.new { api_client.overview rescue {} }
      threads[:equity_curve] = Thread.new { api_client.equity_curve rescue {} }
      threads[:recent_trades] = Thread.new {
        result = api_client.trades(per_page: 20) rescue {}
        result.is_a?(Hash) ? (result["trades"] || []) : Array(result)
      }
      threads[:open_trades] = Thread.new {
        result = api_client.trades(status: "open") rescue {}
        result.is_a?(Hash) ? (result["trades"] || []) : Array(result)
      }
    end

    # Budget API calls
    if budget_api_token.present?
      threads[:budget_overview] = Thread.new { budget_client.budget_overview rescue {} }
      threads[:net_worth] = Thread.new { budget_client.net_worth rescue {} }
      threads[:spending_trends] = Thread.new { budget_client.spending_trends(months: 6) rescue [] }
      threads[:goals] = Thread.new {
        result = budget_client.goals rescue []
        result.is_a?(Array) ? result : (result.is_a?(Hash) ? (result["goals"] || []) : [])
      }
    end

    # Notes API calls
    if notes_api_token.present?
      threads[:notes_stats] = Thread.new { notes_client.stats rescue {} }
    end

    # Collect results
    @trading_overview = threads[:trading_overview]&.value || {}
    equity_result = threads[:equity_curve]&.value || {}
    @equity_curve = equity_result.is_a?(Hash) ? (equity_result["equity_curve"] || []) : []
    @recent_trades = threads[:recent_trades]&.value || []
    @open_trades = threads[:open_trades]&.value || []
    @budget_overview = threads[:budget_overview]&.value || {}
    @net_worth_data = threads[:net_worth]&.value || {}
    @spending_trends = threads[:spending_trends]&.value || []
    @spending_trends = @spending_trends.is_a?(Array) ? @spending_trends : (@spending_trends.is_a?(Hash) ? (@spending_trends["trends"] || []) : [])
    @goals = threads[:goals]&.value || []
    @notes_stats = threads[:notes_stats]&.value || {}

    # === Net Worth Composition ===
    @trading_equity = @trading_overview.is_a?(Hash) ? @trading_overview["account_balance"].to_f : 0
    @budget_net_worth = @net_worth_data.is_a?(Hash) ? (@net_worth_data["net_worth"].to_f) : 0
    @budget_assets = @net_worth_data.is_a?(Hash) ? @net_worth_data["assets"].to_f : 0
    @budget_liabilities = @net_worth_data.is_a?(Hash) ? @net_worth_data["liabilities"].to_f : 0
    @total_net_worth = @trading_equity + @budget_net_worth

    # === Monthly Cash Flow ===
    @trading_pnl_this_month = calculate_trading_pnl_this_month
    @budget_income = @budget_overview.is_a?(Hash) ? @budget_overview["budget_income"].to_f : 0
    @budget_expenses = @budget_overview.is_a?(Hash) ? @budget_overview["total_spent"].to_f : 0
    @monthly_cash_flow = @trading_pnl_this_month + @budget_income - @budget_expenses

    # === Asset Allocation ===
    @savings = @net_worth_data.is_a?(Hash) ? @net_worth_data["savings"].to_f : 0
    @investments = @net_worth_data.is_a?(Hash) ? @net_worth_data["investments"].to_f : 0
    @total_assets = @trading_equity + @savings + @investments
    @allocation = if @total_assets > 0
      {
        trading: ((@trading_equity / @total_assets) * 100).round(1),
        savings: ((@savings / @total_assets) * 100).round(1),
        investments: ((@investments / @total_assets) * 100).round(1)
      }
    else
      { trading: 0, savings: 0, investments: 0 }
    end

    # === 30-Day Trend ===
    @net_worth_30d_ago = calculate_net_worth_30d_ago
    @net_worth_change = @total_net_worth - @net_worth_30d_ago
    @net_worth_trend = @net_worth_change >= 0 ? :up : :down

    # === Risk Exposure ===
    @open_positions_value = @open_trades.sum { |t| t["position_size"].to_f.abs }
    @unrealized_pnl = @open_trades.sum { |t| t["unrealized_pnl"].to_f }
    @risk_exposure = @total_net_worth > 0 ? ((@open_positions_value / @total_net_worth) * 100).round(1) : 0

    # === Monthly Performance (from spending trends + trading) ===
    @monthly_performance = build_monthly_performance
  end

  private

  def calculate_trading_pnl_this_month
    current_month = Date.current.strftime("%Y-%m")
    closed_this_month = @recent_trades.select do |t|
      exit_time = (t["exit_time"] || t["entry_time"]).to_s.slice(0, 7)
      exit_time == current_month && t["status"]&.downcase == "closed"
    end
    closed_this_month.sum { |t| t["pnl"].to_f }
  rescue
    0
  end

  def calculate_net_worth_30d_ago
    # Estimate from equity curve and budget trends
    equity_30d_ago = if @equity_curve.length > 30
      point = @equity_curve[-30]
      point.is_a?(Hash) ? point["equity"].to_f : point.to_f
    elsif @equity_curve.any?
      point = @equity_curve.first
      point.is_a?(Hash) ? point["equity"].to_f : point.to_f
    else
      @trading_equity
    end

    budget_30d_ago = @budget_net_worth
    if @spending_trends.is_a?(Array) && @spending_trends.length >= 2
      last_month = @spending_trends.last
      if last_month.is_a?(Hash)
        monthly_savings = last_month["income"].to_f - last_month["spent"].to_f
        budget_30d_ago = @budget_net_worth - monthly_savings
      end
    end

    equity_30d_ago + budget_30d_ago
  rescue
    @total_net_worth
  end

  def build_monthly_performance
    months = {}

    # Add trading P&L by month from recent trades
    @recent_trades.each do |t|
      next unless t.is_a?(Hash) && t["status"]&.downcase == "closed"
      date = (t["exit_time"] || t["entry_time"]).to_s.slice(0, 7)
      next if date.blank?
      months[date] ||= { trading_pnl: 0, budget_savings: 0 }
      months[date][:trading_pnl] += t["pnl"].to_f
    end

    # Add budget savings from spending trends
    @spending_trends.each do |trend|
      next unless trend.is_a?(Hash)
      month_key = trend["month"] || trend["period"]
      next if month_key.blank?
      months[month_key] ||= { trading_pnl: 0, budget_savings: 0 }
      months[month_key][:budget_savings] = trend["income"].to_f - trend["spent"].to_f
    end

    months.sort_by { |k, _| k }.last(6).map do |month, data|
      {
        month: month,
        trading_pnl: data[:trading_pnl].round(2),
        budget_savings: data[:budget_savings].round(2),
        net_change: (data[:trading_pnl] + data[:budget_savings]).round(2)
      }
    end
  rescue
    []
  end
end

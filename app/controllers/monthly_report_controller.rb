class MonthlyReportController < ApplicationController
  include ActionView::Helpers::NumberHelper

  def show
    @month_offset = params[:month].to_i
    @target_date = Date.current - @month_offset.months
    @month_start = @target_date.beginning_of_month
    @month_end = @target_date.end_of_month
    @month_name = @month_start.strftime("%B %Y")

    threads = {}

    # Trading data
    if api_token.present?
      threads[:trades] = Thread.new {
        result = api_client.trades(
          start_date: @month_start.to_s,
          end_date: (@month_end + 1.day).to_s,
          per_page: 200,
          status: "closed"
        )
        result.is_a?(Hash) ? (result["trades"] || []) : Array(result)
      }
      threads[:journal] = Thread.new {
        result = api_client.journal_entries(
          start_date: @month_start.to_s,
          end_date: @month_end.to_s,
          per_page: 50
        )
        result.is_a?(Hash) ? (result["journal_entries"] || []) : Array(result)
      }
    end

    # Notes data
    if notes_api_token.present?
      threads[:notes] = Thread.new {
        result = notes_client.notes(per_page: 200, sort: "updated_at_desc")
        all = result.is_a?(Hash) ? (result["notes"] || []) : Array(result)
        all.select { |n|
          updated = n["updated_at"] || n["created_at"]
          next false unless updated
          date = Date.parse(updated.to_s) rescue nil
          date && date >= @month_start && date <= @month_end
        }
      }
    end

    # Budget data
    if budget_api_token.present?
      threads[:budget] = Thread.new {
        budget_client.budget_overview(month: @month_start.month, year: @month_start.year) rescue {}
      }
      threads[:transactions] = Thread.new {
        result = budget_client.transactions(
          start_date: @month_start.to_s,
          end_date: @month_end.to_s,
          per_page: 500
        )
        result.is_a?(Hash) ? (result["transactions"] || []) : Array(result)
      }
    end

    # Collect results
    @trades = threads[:trades]&.value || []
    @journal_entries = threads[:journal]&.value || []
    @notes = threads[:notes]&.value || []
    @budget = threads[:budget]&.value || {}
    @transactions = threads[:transactions]&.value || []

    compute_trading_summary
    compute_budget_summary
    compute_notes_summary
    compute_highlights
  end

  private

  def compute_trading_summary
    @trade_count = @trades.count
    @trade_wins = @trades.count { |t| t["pnl"].to_f > 0 }
    @trade_losses = @trades.count { |t| t["pnl"].to_f < 0 }
    @trade_win_rate = @trade_count > 0 ? (@trade_wins.to_f / @trade_count * 100).round(1) : 0
    @trade_pnl = @trades.sum { |t| t["pnl"].to_f }
    @trade_fees = @trades.sum { |t| t["fees"].to_f }
    @best_trade = @trades.max_by { |t| t["pnl"].to_f }
    @worst_trade = @trades.min_by { |t| t["pnl"].to_f }

    # Trading days
    trade_dates = @trades.map { |t| (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 10) }.compact.uniq
    @trading_days = trade_dates.count
    @green_days = 0
    @red_days = 0
    trade_dates.each do |date|
      day_pnl = @trades.select { |t| (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 10) == date }.sum { |t| t["pnl"].to_f }
      day_pnl >= 0 ? @green_days += 1 : @red_days += 1
    end

    # Top symbols
    by_sym = {}
    @trades.each do |t|
      sym = t["symbol"] || "?"
      by_sym[sym] ||= { pnl: 0, count: 0 }
      by_sym[sym][:pnl] += t["pnl"].to_f
      by_sym[sym][:count] += 1
    end
    @top_symbols = by_sym.sort_by { |_, d| -d[:pnl] }.first(5)
  end

  def compute_budget_summary
    @budget_income = @transactions.select { |t| t["transaction_type"] == "income" }.sum { |t| t["amount"].to_f }
    @budget_expenses = @transactions.select { |t| t["transaction_type"] != "income" }.sum { |t| t["amount"].to_f }
    @budget_net = @budget_income - @budget_expenses
    @transaction_count = @transactions.count

    # Top spending categories
    by_cat = {}
    @transactions.select { |t| t["transaction_type"] != "income" }.each do |t|
      cat = t["category"] || t["budget_category"] || "Uncategorized"
      by_cat[cat] ||= 0
      by_cat[cat] += t["amount"].to_f
    end
    @top_categories = by_cat.sort_by { |_, v| -v }.first(5)

    @budgeted = @budget.is_a?(Hash) ? @budget["total_budgeted"].to_f : 0
    @budget_utilization = @budgeted > 0 ? (@budget_expenses / @budgeted * 100).round(1) : 0
  end

  def compute_notes_summary
    @notes_created = @notes.count
    @notes_words = @notes.sum { |n| n["word_count"].to_i }
    @notes_notebooks = @notes.map { |n| n.dig("notebook", "name") }.compact.uniq.count
  end

  def compute_highlights
    @highlights = []

    # Trading highlights
    if @trade_pnl > 0
      @highlights << { icon: "trending_up", color: "var(--positive)", text: "Profitable month: #{number_to_currency(@trade_pnl)} from #{@trade_count} trades" }
    elsif @trade_count > 0
      @highlights << { icon: "trending_down", color: "var(--negative)", text: "#{number_to_currency(@trade_pnl)} trading P&L from #{@trade_count} trades" }
    end

    if @trade_win_rate >= 60 && @trade_count >= 5
      @highlights << { icon: "stars", color: "var(--positive)", text: "Strong #{@trade_win_rate}% win rate this month" }
    end

    # Budget highlights
    if @budget_net > 0
      @highlights << { icon: "savings", color: "var(--positive)", text: "Saved #{number_to_currency(@budget_net)} this month" }
    elsif @budget_net < 0
      @highlights << { icon: "warning", color: "var(--negative)", text: "Overspent by #{number_to_currency(@budget_net.abs)} this month" }
    end

    if @budget_utilization > 0 && @budget_utilization <= 90
      @highlights << { icon: "check_circle", color: "var(--positive)", text: "Under budget at #{@budget_utilization}% utilization" }
    elsif @budget_utilization > 100
      @highlights << { icon: "error", color: "var(--negative)", text: "Over budget at #{@budget_utilization}% utilization" }
    end

    # Notes highlights
    if @notes_created >= 10
      @highlights << { icon: "description", color: "#1a73e8", text: "#{@notes_created} notes created — great documentation month!" }
    end

    if @journal_entries.count >= 15
      @highlights << { icon: "auto_stories", color: "#9c27b0", text: "#{@journal_entries.count} journal entries — excellent discipline" }
    end
  end
end

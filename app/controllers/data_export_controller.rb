class DataExportController < ApplicationController
  def index
    threads = {}
    threads[:trades] = Thread.new { api_client.trades(per_page: 1) rescue {} }
    threads[:journal] = Thread.new { api_client.journal_entries(per_page: 1) rescue {} }
    threads[:notes] = Thread.new { notes_client.stats rescue {} }
    threads[:playbooks] = Thread.new { api_client.playbooks rescue [] }
    threads[:budget] = Thread.new { budget_client.budget_overview rescue {} }

    trades_result = threads[:trades].value
    @trades_count = trades_result.is_a?(Hash) ? (trades_result.dig("meta", "total_count") || trades_result["total_count"] || 0) : 0

    journal_result = threads[:journal].value
    journal_entries = journal_result.is_a?(Hash) ? (journal_result["journal_entries"] || []) : (journal_result || [])
    @journal_count = journal_result.is_a?(Hash) ? (journal_result.dig("meta", "total_count") || journal_entries.count) : journal_entries.count

    notes_result = threads[:notes].value
    @notes_count = notes_result.is_a?(Hash) ? (notes_result["total_notes"] || notes_result["notes_count"] || 0) : 0

    playbooks_result = threads[:playbooks].value
    playbooks_arr = playbooks_result.is_a?(Hash) ? (playbooks_result["playbooks"] || [playbooks_result]) : (playbooks_result || [])
    @playbooks_count = playbooks_arr.is_a?(Array) ? playbooks_arr.count : 0

    budget_result = threads[:budget].value
    @budget_connected = budget_result.is_a?(Hash) && !budget_result["error"]
  end

  def trades_csv
    csv = api_client.export_trades
    send_data csv, filename: "trades_#{Date.today}.csv", type: "text/csv"
  end

  def notes_json
    result = notes_client.notes(per_page: 10000)
    notes = result["notes"] || result
    send_data notes.to_json, filename: "notes_#{Date.today}.json", type: "application/json"
  end

  def playbooks_md
    result = api_client.playbooks
    playbooks = result.is_a?(Hash) ? (result["playbooks"] || [result]) : (result || [])
    playbooks = Array.wrap(playbooks).reject { |p| p.is_a?(Hash) && p["error"] }

    md = "# Trading Playbooks\n\nExported: #{Date.today}\n\n"
    playbooks.each do |pb|
      md << "---\n\n## #{pb["name"]}\n\n"
      md << "**Status:** #{pb["status"]&.capitalize}\n" if pb["status"]
      md << "**Asset Classes:** #{pb["asset_classes"]}\n" if pb["asset_classes"].present?
      md << "**Timeframes:** #{pb["timeframes"]}\n" if pb["timeframes"].present?
      md << "\n#{pb["description"]}\n" if pb["description"].present?
      md << "\n### Setup Rules\n\n#{pb["setup_rules"]}\n" if pb["setup_rules"].present?
      md << "\n### Entry Criteria\n\n#{pb["entry_criteria"]}\n" if pb["entry_criteria"].present?
      md << "\n### Exit Criteria\n\n#{pb["exit_criteria"]}\n" if pb["exit_criteria"].present?
      md << "\n### Risk Management\n\n#{pb["risk_rules"]}\n" if pb["risk_rules"].present?
      md << "\n"
    end

    send_data md, filename: "playbooks_#{Date.today}.md", type: "text/markdown"
  end

  def journal_csv
    entries = api_client.journal_entries(per_page: 10000)
    entries = entries["journal_entries"] || entries
    csv = generate_journal_csv(entries)
    send_data csv, filename: "journal_entries_#{Date.today}.csv", type: "text/csv"
  end

  def budget_transactions_csv
    csv = budget_client.export_transactions
    send_data csv, filename: "budget_transactions_#{Date.today}.csv", type: "text/csv"
  end

  def account_statement
    @start_date = params[:start_date].present? ? Date.parse(params[:start_date]) : Date.current.beginning_of_month
    @end_date = params[:end_date].present? ? Date.parse(params[:end_date]) : Date.current

    threads = {}
    threads[:trades] = Thread.new {
      result = api_client.trades(
        start_date: @start_date.to_s,
        end_date: (@end_date + 1.day).to_s,
        per_page: 500,
        status: "closed"
      )
      result.is_a?(Hash) ? (result["trades"] || []) : Array(result)
    }
    threads[:overview] = Thread.new { api_client.overview rescue {} }
    threads[:streaks] = Thread.new { api_client.streaks rescue {} }

    @trades = threads[:trades].value
    @overview = threads[:overview].value || {}
    @streaks = threads[:streaks].value || {}

    # Period stats
    @total_trades = @trades.count
    @winners = @trades.select { |t| t["pnl"].to_f > 0 }
    @losers = @trades.select { |t| t["pnl"].to_f < 0 }
    @breakeven = @trades.select { |t| t["pnl"].to_f == 0 }
    @win_rate = @total_trades > 0 ? (@winners.count.to_f / @total_trades * 100).round(1) : 0
    @total_pnl = @trades.sum { |t| t["pnl"].to_f }
    @total_fees = @trades.sum { |t| t["fees"].to_f }
    @net_pnl = @total_pnl - @total_fees
    @avg_win = @winners.any? ? (@winners.sum { |t| t["pnl"].to_f } / @winners.count).round(2) : 0
    @avg_loss = @losers.any? ? (@losers.sum { |t| t["pnl"].to_f } / @losers.count).round(2) : 0
    @largest_win = @trades.map { |t| t["pnl"].to_f }.max || 0
    @largest_loss = @trades.map { |t| t["pnl"].to_f }.min || 0
    @profit_factor = @losers.any? ? (@winners.sum { |t| t["pnl"].to_f } / @losers.sum { |t| t["pnl"].to_f }.abs).round(2) : 0

    # Equity curve for the period
    running = 0
    @equity_curve = @trades.sort_by { |t| t["exit_time"] || t["entry_time"] || "" }.map { |t|
      running += t["pnl"].to_f
      { date: (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 10), pnl: t["pnl"].to_f, cumulative: running.round(2) }
    }

    # Max drawdown
    peak = 0
    @max_drawdown = 0
    @equity_curve.each do |pt|
      peak = [peak, pt[:cumulative]].max
      dd = peak - pt[:cumulative]
      @max_drawdown = [dd, @max_drawdown].max
    end

    # By symbol summary
    @by_symbol = {}
    @trades.each do |t|
      sym = t["symbol"] || "Unknown"
      @by_symbol[sym] ||= { trades: 0, wins: 0, pnl: 0 }
      @by_symbol[sym][:trades] += 1
      @by_symbol[sym][:wins] += 1 if t["pnl"].to_f > 0
      @by_symbol[sym][:pnl] += t["pnl"].to_f
    end
    @by_symbol = @by_symbol.sort_by { |_, d| -d[:pnl] }.to_h

    # Daily P&L
    @daily_pnl = {}
    @trades.each do |t|
      date = (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 10)
      next unless date
      @daily_pnl[date] ||= 0
      @daily_pnl[date] += t["pnl"].to_f
    end
    @green_days = @daily_pnl.count { |_, v| v > 0 }
    @red_days = @daily_pnl.count { |_, v| v < 0 }
    @trading_days = @daily_pnl.count
  end

  def budget_summary_json
    threads = {}
    threads[:overview] = Thread.new { budget_client.budget_overview }
    threads[:net_worth] = Thread.new { budget_client.net_worth }
    threads[:debt] = Thread.new { budget_client.debt_overview }
    threads[:funds] = Thread.new { budget_client.funds }
    threads[:goals] = Thread.new { budget_client.goals }

    summary = {
      exported_at: Time.current.iso8601,
      overview: threads[:overview].value,
      net_worth: threads[:net_worth].value,
      debt: threads[:debt].value,
      funds: threads[:funds].value,
      goals: threads[:goals].value
    }

    send_data summary.to_json, filename: "budget_summary_#{Date.today}.json", type: "application/json"
  end

  private

  def generate_journal_csv(entries)
    return "" unless entries.is_a?(Array)

    require "csv"
    CSV.generate do |csv|
      csv << %w[Date Mood Content Market_Conditions Plan Review Daily_PnL]
      entries.each do |entry|
        csv << [
          entry["date"],
          entry["mood"],
          entry["content"],
          entry["market_conditions"],
          entry["plan"],
          entry["review"],
          entry["daily_pnl"]
        ]
      end
    end
  end
end

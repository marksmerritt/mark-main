class CrossProductInsightsController < ApplicationController
  include ActionView::Helpers::NumberHelper

  def show
    threads = {}

    if api_token.present?
      threads[:trades] = Thread.new { api_client.trades(per_page: 500) rescue {} }
      threads[:journal] = Thread.new { api_client.journal_entries(per_page: 200) rescue {} }
      threads[:stats] = Thread.new { api_client.overview rescue {} }
    end

    if notes_api_token.present?
      threads[:notes] = Thread.new { notes_client.notes(per_page: 500) rescue {} }
    end

    if budget_api_token.present?
      threads[:transactions] = Thread.new { budget_client.transactions(per_page: 500) rescue {} }
    end

    trades_result = threads[:trades]&.value || {}
    @trades = trades_result.is_a?(Hash) ? (trades_result["trades"] || []) : Array(trades_result)
    @trades = @trades.select { |t| t.is_a?(Hash) && t["status"] == "closed" }

    journal_result = threads[:journal]&.value || {}
    @journal = journal_result.is_a?(Hash) ? (journal_result["journal_entries"] || []) : Array(journal_result)

    @stats = threads[:stats]&.value || {}
    @stats = {} unless @stats.is_a?(Hash)

    notes_result = threads[:notes]&.value || {}
    @notes = notes_result.is_a?(Hash) ? (notes_result["notes"] || []) : Array(notes_result)
    @notes = @notes.select { |n| n.is_a?(Hash) }

    txn_result = threads[:transactions]&.value || {}
    @transactions = txn_result.is_a?(Hash) ? (txn_result["transactions"] || txn_result) : Array(txn_result)
    @transactions = @transactions.is_a?(Array) ? @transactions.select { |t| t.is_a?(Hash) } : []

    compute_daily_activity
    compute_correlations
    compute_product_health
    find_patterns
  end

  private

  def compute_daily_activity
    @daily = {}
    last_90 = Date.today - 89

    @trades.each do |t|
      date = (t["entry_time"] || t["exit_time"])&.to_s&.slice(0, 10)
      next unless date
      d = Date.parse(date) rescue nil
      next unless d && d >= last_90
      @daily[d] ||= default_day
      @daily[d][:trades] += 1
      @daily[d][:pnl] += t["pnl"].to_f
      @daily[d][:wins] += 1 if t["pnl"].to_f > 0
    end

    @journal.each do |j|
      date = (j["date"] || j["created_at"])&.to_s&.slice(0, 10)
      next unless date
      d = Date.parse(date) rescue nil
      next unless d && d >= last_90
      @daily[d] ||= default_day
      @daily[d][:journaled] = true
      @daily[d][:mood] = j["mood"]&.downcase
    end

    @notes.each do |n|
      date = (n["updated_at"] || n["created_at"])&.to_s&.slice(0, 10)
      next unless date
      d = Date.parse(date) rescue nil
      next unless d && d >= last_90
      @daily[d] ||= default_day
      @daily[d][:notes] += 1
      content = n["content"] || n["body"] || ""
      @daily[d][:words] += content.split(/\s+/).reject(&:blank?).count
    end

    @transactions.each do |t|
      date = (t["transaction_date"] || t["date"])&.to_s&.slice(0, 10)
      next unless date
      d = Date.parse(date) rescue nil
      next unless d && d >= last_90
      @daily[d] ||= default_day
      @daily[d][:spending] += t["amount"].to_f.abs if t["transaction_type"] == "expense"
    end
  end

  def compute_correlations
    @correlations = []

    # Journal days vs non-journal days trading performance
    journal_days = @daily.select { |_, d| d[:journaled] && d[:trades] > 0 }
    no_journal_days = @daily.select { |_, d| !d[:journaled] && d[:trades] > 0 }

    if journal_days.any? && no_journal_days.any?
      j_avg = journal_days.values.sum { |d| d[:pnl] } / journal_days.size
      nj_avg = no_journal_days.values.sum { |d| d[:pnl] } / no_journal_days.size
      j_wr = journal_days.values.any? ? (journal_days.values.sum { |d| d[:wins] }.to_f / journal_days.values.sum { |d| d[:trades] } * 100).round(1) : 0
      nj_wr = no_journal_days.values.any? ? (no_journal_days.values.sum { |d| d[:wins] }.to_f / no_journal_days.values.sum { |d| d[:trades] } * 100).round(1) : 0

      @correlations << {
        title: "Journal Days vs Non-Journal Days",
        icon: "auto_stories",
        findings: [
          { label: "Avg P&L (journal days)", value: number_to_currency(j_avg.round(2)), positive: j_avg > nj_avg },
          { label: "Avg P&L (no journal)", value: number_to_currency(nj_avg.round(2)), positive: false },
          { label: "Win Rate (journal)", value: "#{j_wr}%", positive: j_wr > nj_wr },
          { label: "Win Rate (no journal)", value: "#{nj_wr}%", positive: false },
          { label: "P&L Difference", value: number_to_currency((j_avg - nj_avg).round(2)), positive: j_avg > nj_avg }
        ]
      }
    end

    # Note-writing days vs trading performance
    note_days = @daily.select { |_, d| d[:notes] > 0 && d[:trades] > 0 }
    no_note_days = @daily.select { |_, d| d[:notes] == 0 && d[:trades] > 0 }

    if note_days.any? && no_note_days.any?
      n_avg = note_days.values.sum { |d| d[:pnl] } / note_days.size
      nn_avg = no_note_days.values.sum { |d| d[:pnl] } / no_note_days.size

      @correlations << {
        title: "Note-Writing Days vs Non-Writing Days",
        icon: "description",
        findings: [
          { label: "Avg P&L (writing days)", value: number_to_currency(n_avg.round(2)), positive: n_avg > nn_avg },
          { label: "Avg P&L (non-writing)", value: number_to_currency(nn_avg.round(2)), positive: false },
          { label: "# Writing + Trading Days", value: note_days.size.to_s, positive: true },
          { label: "# Non-Writing Trading Days", value: no_note_days.size.to_s, positive: false }
        ]
      }
    end

    # Spending vs Trading performance
    trading_days = @daily.select { |_, d| d[:trades] > 0 }
    if trading_days.size >= 10
      median_spend = trading_days.values.map { |d| d[:spending] }.sort[trading_days.size / 2]
      high_spend = trading_days.select { |_, d| d[:spending] > median_spend && d[:spending] > 0 }
      low_spend = trading_days.select { |_, d| d[:spending] <= median_spend || d[:spending] == 0 }

      if high_spend.any? && low_spend.any?
        hs_avg = high_spend.values.sum { |d| d[:pnl] } / high_spend.size
        ls_avg = low_spend.values.sum { |d| d[:pnl] } / low_spend.size

        @correlations << {
          title: "High Spending Days vs Low Spending Days",
          icon: "shopping_cart",
          findings: [
            { label: "Avg P&L (high spend days)", value: number_to_currency(hs_avg.round(2)), positive: hs_avg > ls_avg },
            { label: "Avg P&L (low spend days)", value: number_to_currency(ls_avg.round(2)), positive: ls_avg > hs_avg },
            { label: "High spend days", value: high_spend.size.to_s, positive: false },
            { label: "Low spend days", value: low_spend.size.to_s, positive: true }
          ]
        }
      end
    end
  end

  def compute_product_health
    last_7 = Date.today - 6
    last_30 = Date.today - 29
    recent = @daily.select { |d, _| d >= last_7 }
    month = @daily.select { |d, _| d >= last_30 }

    @health = {
      trading: {
        active_days_7: recent.count { |_, d| d[:trades] > 0 },
        active_days_30: month.count { |_, d| d[:trades] > 0 },
        total_pnl_7: recent.values.sum { |d| d[:pnl] },
        total_pnl_30: month.values.sum { |d| d[:pnl] }
      },
      journal: {
        active_days_7: recent.count { |_, d| d[:journaled] },
        active_days_30: month.count { |_, d| d[:journaled] }
      },
      notes: {
        active_days_7: recent.count { |_, d| d[:notes] > 0 },
        active_days_30: month.count { |_, d| d[:notes] > 0 },
        words_7: recent.values.sum { |d| d[:words] },
        words_30: month.values.sum { |d| d[:words] }
      },
      budget: {
        active_days_7: recent.count { |_, d| d[:spending] > 0 },
        active_days_30: month.count { |_, d| d[:spending] > 0 },
        spending_7: recent.values.sum { |d| d[:spending] },
        spending_30: month.values.sum { |d| d[:spending] }
      }
    }
  end

  def find_patterns
    @patterns = []

    # Best day type
    trading_days = @daily.select { |_, d| d[:trades] > 0 }
    return if trading_days.size < 5

    # Does journaling correlate with better trading?
    j_days = trading_days.select { |_, d| d[:journaled] }
    nj_days = trading_days.reject { |_, d| d[:journaled] }
    if j_days.size >= 3 && nj_days.size >= 3
      j_avg = j_days.values.sum { |d| d[:pnl] } / j_days.size
      nj_avg = nj_days.values.sum { |d| d[:pnl] } / nj_days.size
      if j_avg > nj_avg * 1.5
        @patterns << { icon: "auto_stories", color: "var(--positive)", text: "Journaling boosts your trading! Avg P&L is #{((j_avg / [nj_avg.abs, 1].max - 1) * 100).round(0)}% better on journal days." }
      elsif nj_avg > j_avg * 1.5
        @patterns << { icon: "auto_stories", color: "#f9a825", text: "Interestingly, your non-journal days perform better. Perhaps you journal more on difficult days?" }
      end
    end

    # Active vs quiet days
    multi_product_days = @daily.select { |_, d| [d[:trades] > 0, d[:journaled], d[:notes] > 0, d[:spending] > 0].count(true) >= 3 }
    if multi_product_days.size >= 3
      mp_avg = multi_product_days.values.sum { |d| d[:pnl] } / multi_product_days.size
      @patterns << { icon: "hub", color: "#1976d2", text: "On days you engage with 3+ products, your avg P&L is #{number_to_currency(mp_avg.round(2))}. #{mp_avg > 0 ? 'Active days correlate with better results.' : 'Consider a more focused approach.'}" }
    end

    # Weekend note-writing
    weekend_notes = @daily.select { |d, data| [0, 6].include?(d.wday) && data[:notes] > 0 }
    if weekend_notes.size >= 2
      @patterns << { icon: "weekend", color: "#7b1fa2", text: "You write notes on weekends (#{weekend_notes.size} days). Reflection during downtime builds trading edge." }
    end
  end

  def default_day
    { trades: 0, pnl: 0.0, wins: 0, journaled: false, mood: nil, notes: 0, words: 0, spending: 0.0 }
  end
end

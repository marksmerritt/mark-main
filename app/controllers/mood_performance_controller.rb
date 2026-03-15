class MoodPerformanceController < ApplicationController
  before_action :require_api_connection

  include ActionView::Helpers::NumberHelper

  def show
    threads = {}
    threads[:trades] = Thread.new { api_client.trades(per_page: 500) rescue {} }
    threads[:journal] = Thread.new { api_client.journal_entries(per_page: 500) rescue {} }

    trades_result = threads[:trades].value
    @trades = trades_result.is_a?(Hash) ? (trades_result["trades"] || []) : Array(trades_result)
    @trades = @trades.select { |t| t.is_a?(Hash) && t["status"] == "closed" }

    journal_result = threads[:journal].value
    @journal = journal_result.is_a?(Hash) ? (journal_result["journal_entries"] || []) : Array(journal_result)
    @journal = @journal.select { |j| j.is_a?(Hash) }

    correlate_mood_and_performance
    analyze_market_conditions
    build_mood_calendar
    generate_recommendations
  end

  private

  def correlate_mood_and_performance
    # Build a map of journal moods by date
    mood_by_date = {}
    @journal.each do |j|
      date = (j["date"] || j["created_at"])&.to_s&.slice(0, 10)
      next unless date && j["mood"].present?
      mood_by_date[date] = j["mood"].downcase.strip
    end

    # Match trades with journal moods
    @mood_trades = {}
    unmatched = 0
    @trades.each do |t|
      date = (t["entry_time"] || t["exit_time"])&.to_s&.slice(0, 10)
      next unless date
      mood = mood_by_date[date]
      unless mood
        unmatched += 1
        next
      end
      @mood_trades[mood] ||= { trades: [], pnl: 0, wins: 0, count: 0 }
      @mood_trades[mood][:trades] << t
      @mood_trades[mood][:pnl] += t["pnl"].to_f
      @mood_trades[mood][:count] += 1
      @mood_trades[mood][:wins] += 1 if t["pnl"].to_f > 0
    end
    @unmatched_count = unmatched

    # Calculate stats per mood
    @mood_stats = @mood_trades.map do |mood, data|
      wr = data[:count] > 0 ? (data[:wins].to_f / data[:count] * 100).round(1) : 0
      avg = data[:count] > 0 ? (data[:pnl] / data[:count]).round(2) : 0
      {
        mood: mood.capitalize,
        count: data[:count],
        pnl: data[:pnl],
        win_rate: wr,
        avg_pnl: avg,
        wins: data[:wins],
        losses: data[:count] - data[:wins]
      }
    end.sort_by { |m| -m[:pnl] }

    # Best and worst moods
    @best_mood = @mood_stats.first
    @worst_mood = @mood_stats.last

    # Overall stats
    @total_matched = @mood_trades.values.sum { |d| d[:count] }
    @match_rate = @trades.any? ? (@total_matched.to_f / @trades.size * 100).round(0) : 0

    # Mood categories for visualization
    @positive_moods = %w[confident disciplined focused calm optimistic excited motivated]
    @negative_moods = %w[anxious frustrated angry fearful stressed impatient greedy]
    @neutral_moods = %w[neutral uncertain tired bored indifferent]

    @positive_pnl = @mood_stats.select { |m| @positive_moods.include?(m[:mood].downcase) }.sum { |m| m[:pnl] }
    @negative_pnl = @mood_stats.select { |m| @negative_moods.include?(m[:mood].downcase) }.sum { |m| m[:pnl] }
    @neutral_pnl = @mood_stats.select { |m| @neutral_moods.include?(m[:mood].downcase) }.sum { |m| m[:pnl] }

    @positive_wr = begin
      pos = @mood_stats.select { |m| @positive_moods.include?(m[:mood].downcase) }
      total = pos.sum { |m| m[:count] }
      wins = pos.sum { |m| m[:wins] }
      total > 0 ? (wins.to_f / total * 100).round(1) : 0
    end
    @negative_wr = begin
      neg = @mood_stats.select { |m| @negative_moods.include?(m[:mood].downcase) }
      total = neg.sum { |m| m[:count] }
      wins = neg.sum { |m| m[:wins] }
      total > 0 ? (wins.to_f / total * 100).round(1) : 0
    end
  end

  def analyze_market_conditions
    # Group by market_conditions from journal
    conditions_by_date = {}
    @journal.each do |j|
      date = (j["date"] || j["created_at"])&.to_s&.slice(0, 10)
      next unless date && j["market_conditions"].present?
      conditions_by_date[date] = j["market_conditions"].downcase.strip
    end

    @condition_stats = {}
    @trades.each do |t|
      date = (t["entry_time"] || t["exit_time"])&.to_s&.slice(0, 10)
      next unless date
      cond = conditions_by_date[date]
      next unless cond
      @condition_stats[cond] ||= { count: 0, pnl: 0, wins: 0 }
      @condition_stats[cond][:count] += 1
      @condition_stats[cond][:pnl] += t["pnl"].to_f
      @condition_stats[cond][:wins] += 1 if t["pnl"].to_f > 0
    end

    @condition_stats = @condition_stats.map do |cond, data|
      {
        condition: cond.split(/[\s_]/).map(&:capitalize).join(" "),
        count: data[:count],
        pnl: data[:pnl],
        win_rate: data[:count] > 0 ? (data[:wins].to_f / data[:count] * 100).round(1) : 0
      }
    end.sort_by { |c| -c[:pnl] }
  end

  def build_mood_calendar
    @mood_calendar = {}
    @journal.each do |j|
      date = (j["date"] || j["created_at"])&.to_s&.slice(0, 10)
      next unless date
      mood = j["mood"]&.downcase&.strip
      @mood_calendar[date] = mood
    end

    # Last 30 days
    today = Date.today
    @calendar_days = (today - 29..today).map do |d|
      ds = d.strftime("%Y-%m-%d")
      trade_pnl = @trades.select { |t| (t["entry_time"] || t["exit_time"])&.to_s&.slice(0, 10) == ds }.sum { |t| t["pnl"].to_f }
      has_trades = @trades.any? { |t| (t["entry_time"] || t["exit_time"])&.to_s&.slice(0, 10) == ds }
      {
        date: d,
        mood: @mood_calendar[ds],
        pnl: trade_pnl,
        has_trades: has_trades,
        is_today: d == today
      }
    end
  end

  def generate_recommendations
    @recommendations = []

    if @best_mood && @best_mood[:count] >= 3
      @recommendations << {
        icon: "emoji_emotions",
        color: "var(--positive)",
        text: "You trade best when feeling #{@best_mood[:mood]} — #{@best_mood[:win_rate]}% win rate, #{number_to_currency(@best_mood[:avg_pnl])} avg P&L."
      }
    end

    if @worst_mood && @worst_mood[:pnl] < 0 && @worst_mood[:count] >= 3
      @recommendations << {
        icon: "do_not_disturb",
        color: "var(--negative)",
        text: "Consider not trading when feeling #{@worst_mood[:mood]} — #{@worst_mood[:win_rate]}% win rate, #{number_to_currency(@worst_mood[:pnl])} total losses."
      }
    end

    if @positive_pnl > 0 && @negative_pnl < 0
      diff = @positive_pnl - @negative_pnl
      @recommendations << {
        icon: "compare_arrows",
        color: "#1976d2",
        text: "Positive mood states outperform negative by #{number_to_currency(diff)}. Emotional awareness directly impacts your bottom line."
      }
    end

    if @match_rate < 50
      @recommendations << {
        icon: "edit_note",
        color: "#f9a825",
        text: "Only #{@match_rate}% of your trades have journal entries. Increase journaling to unlock deeper mood-performance insights."
      }
    end

    best_condition = @condition_stats.first
    if best_condition && best_condition[:count] >= 3
      @recommendations << {
        icon: "cloud",
        color: "#00897b",
        text: "You perform best in #{best_condition[:condition]} conditions — #{best_condition[:win_rate]}% win rate, #{number_to_currency(best_condition[:pnl])} total."
      }
    end
  end
end

class JournalInsightsController < ApplicationController
  before_action :require_api_connection

  include ActionView::Helpers::NumberHelper

  def show
    threads = {}
    threads[:journal] = Thread.new { api_client.journal_entries(per_page: 500) }
    threads[:trades] = Thread.new { api_client.trades(per_page: 2000, status: "closed") }
    threads[:streaks] = Thread.new { api_client.streaks rescue {} }

    journal_result = threads[:journal].value
    @entries = journal_result.is_a?(Hash) ? (journal_result["journal_entries"] || []) : Array(journal_result)
    @entries = @entries.select { |e| e.is_a?(Hash) }

    trade_result = threads[:trades].value
    all_trades = trade_result.is_a?(Hash) ? (trade_result["trades"] || []) : Array(trade_result)

    streaks_result = threads[:streaks].value || {}

    # Journal stats
    @total_entries = @entries.count
    @current_streak = streaks_result.is_a?(Hash) ? (streaks_result["journal_streak"] || streaks_result["current_journal_streak"] || 0) : 0
    @longest_streak = streaks_result.is_a?(Hash) ? (streaks_result["longest_journal_streak"] || @current_streak) : 0

    # Mood distribution
    @moods = {}
    @entries.each do |e|
      mood = e["mood"].presence || "Unset"
      @moods[mood] ||= 0
      @moods[mood] += 1
    end
    @moods = @moods.sort_by { |_, v| -v }.to_h

    # Build date-indexed trade P&L
    trade_by_date = {}
    all_trades.each do |t|
      date = (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 10)
      next unless date
      trade_by_date[date] ||= { pnl: 0, count: 0, wins: 0 }
      trade_by_date[date][:pnl] += t["pnl"].to_f
      trade_by_date[date][:count] += 1
      trade_by_date[date][:wins] += 1 if t["pnl"].to_f > 0
    end

    # Mood → Performance correlation
    @mood_performance = {}
    @entries.each do |e|
      mood = e["mood"].presence
      next unless mood
      date = e["date"]&.to_s&.slice(0, 10)
      next unless date
      trading = trade_by_date[date]
      next unless trading

      @mood_performance[mood] ||= { days: 0, total_pnl: 0, wins: 0, total_trades: 0 }
      @mood_performance[mood][:days] += 1
      @mood_performance[mood][:total_pnl] += trading[:pnl]
      @mood_performance[mood][:wins] += trading[:wins]
      @mood_performance[mood][:total_trades] += trading[:count]
    end

    @mood_performance.each do |mood, data|
      data[:avg_pnl] = (data[:total_pnl] / [data[:days], 1].max).round(2)
      data[:win_rate] = data[:total_trades] > 0 ? (data[:wins].to_f / data[:total_trades] * 100).round(1) : 0
    end

    # Journal days vs no-journal days performance
    journal_dates = @entries.map { |e| e["date"]&.to_s&.slice(0, 10) }.compact.uniq
    @journal_day_pnl = 0
    @journal_day_trades = 0
    @no_journal_day_pnl = 0
    @no_journal_day_trades = 0

    trade_by_date.each do |date, data|
      if journal_dates.include?(date)
        @journal_day_pnl += data[:pnl]
        @journal_day_trades += data[:count]
      else
        @no_journal_day_pnl += data[:pnl]
        @no_journal_day_trades += data[:count]
      end
    end

    @journal_day_avg = @journal_day_trades > 0 ? (@journal_day_pnl / @journal_day_trades).round(2) : 0
    @no_journal_day_avg = @no_journal_day_trades > 0 ? (@no_journal_day_pnl / @no_journal_day_trades).round(2) : 0

    # Word count analysis
    @word_counts = @entries.map { |e|
      content = e["content"] || e["body"] || ""
      { date: e["date"], words: content.split(/\s+/).count, mood: e["mood"] }
    }
    @avg_words = @word_counts.any? ? (@word_counts.sum { |w| w[:words] } / @word_counts.count).round(0) : 0
    @total_words = @word_counts.sum { |w| w[:words] }

    # Weekly journaling frequency
    @weekly_frequency = {}
    @entries.each do |e|
      date = Date.parse(e["date"]) rescue nil
      next unless date
      week = date.beginning_of_week.to_s
      @weekly_frequency[week] ||= 0
      @weekly_frequency[week] += 1
    end
    @weekly_frequency = @weekly_frequency.sort_by { |k, _| k }.last(12).to_h

    # Time-of-day patterns (if timestamp available)
    @time_distribution = Array.new(24, 0)
    @entries.each do |e|
      ts = e["created_at"] || e["date"]
      next unless ts.to_s.include?("T") || ts.to_s.include?(":")
      hour = Time.parse(ts).hour rescue nil
      @time_distribution[hour] += 1 if hour
    end

    # Insights
    @insights = []

    if @journal_day_avg > @no_journal_day_avg && @journal_day_trades >= 5
      @insights << { icon: "auto_awesome", color: "var(--positive)", text: "You average #{number_to_currency(@journal_day_avg)} per trade on journaling days vs #{number_to_currency(@no_journal_day_avg)} on non-journaling days." }
    elsif @no_journal_day_avg > @journal_day_avg && @no_journal_day_trades >= 5
      @insights << { icon: "info", color: "var(--primary)", text: "Trading performance is slightly better on non-journaling days. Consider if journaling timing affects your mindset." }
    end

    best_mood = @mood_performance.max_by { |_, d| d[:avg_pnl] }
    worst_mood = @mood_performance.min_by { |_, d| d[:avg_pnl] }
    if best_mood && worst_mood && best_mood[0] != worst_mood[0]
      @insights << { icon: "mood", color: "var(--positive)", text: "Best trading mood: #{best_mood[0]} (avg #{number_to_currency(best_mood[1][:avg_pnl])}). Worst: #{worst_mood[0]} (avg #{number_to_currency(worst_mood[1][:avg_pnl])})." }
    end

    if @current_streak >= 5
      @insights << { icon: "local_fire_department", color: "#ff5722", text: "#{@current_streak}-day journal streak! Consistency builds trading discipline." }
    elsif @current_streak == 0 && @total_entries > 0
      @insights << { icon: "edit_note", color: "var(--text-secondary)", text: "Your journal streak has lapsed. A quick entry today can restart the habit." }
    end

    most_common = @moods.first
    if most_common && most_common[1] > @total_entries * 0.4
      @insights << { icon: "psychology", color: "var(--primary)", text: "#{most_common[0]} is your dominant mood (#{(most_common[1].to_f / @total_entries * 100).round(0)}% of entries). Consider diversifying your emotional awareness." }
    end
  end
end

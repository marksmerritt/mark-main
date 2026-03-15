class TrendAnalyzerController < ApplicationController
  before_action :require_api_connection

  include ActionView::Helpers::NumberHelper

  def show
    threads = {}
    threads[:trades] = Thread.new { api_client.trades(per_page: 500) rescue {} }
    threads[:journal] = Thread.new { api_client.journal_entries(per_page: 200) rescue {} }
    threads[:stats] = Thread.new { api_client.overview rescue {} }

    trades_result = threads[:trades].value
    @trades = trades_result.is_a?(Hash) ? (trades_result["trades"] || []) : Array(trades_result)
    @trades = @trades.select { |t| t.is_a?(Hash) && t["status"] == "closed" }

    journal_result = threads[:journal].value
    @journal = journal_result.is_a?(Hash) ? (journal_result["journal_entries"] || []) : Array(journal_result)

    @stats = threads[:stats].value || {}
    @stats = {} unless @stats.is_a?(Hash)

    analyze_performance_trends
    analyze_behavioral_trends
    analyze_seasonal_patterns
    analyze_regime_changes
    generate_insights
  end

  private

  def analyze_performance_trends
    # Split trades into 4 equal quarters for trend detection
    return if @trades.size < 8

    sorted = @trades.sort_by { |t| t["exit_time"] || t["entry_time"] || "" }
    quarter_size = sorted.size / 4
    @quarters = (0..3).map do |q|
      start = q * quarter_size
      finish = q == 3 ? sorted.size : (q + 1) * quarter_size
      chunk = sorted[start...finish]
      wins = chunk.count { |t| t["pnl"].to_f > 0 }
      {
        label: "Q#{q + 1}",
        trades: chunk.size,
        pnl: chunk.sum { |t| t["pnl"].to_f },
        win_rate: chunk.any? ? (wins.to_f / chunk.size * 100).round(1) : 0,
        avg_pnl: chunk.any? ? (chunk.sum { |t| t["pnl"].to_f } / chunk.size).round(2) : 0,
        avg_hold: chunk.any? ? avg_hold_time(chunk) : "N/A"
      }
    end

    # Rolling 20-trade average for trend line
    @rolling_avg = []
    window = [20, sorted.size / 5].max
    sorted.each_cons(window).with_index do |batch, i|
      avg = batch.sum { |t| t["pnl"].to_f } / batch.size
      wr = (batch.count { |t| t["pnl"].to_f > 0 }.to_f / batch.size * 100).round(1)
      @rolling_avg << { index: i, avg_pnl: avg.round(2), win_rate: wr }
    end

    # Trend direction
    if @rolling_avg.size >= 2
      first_half = @rolling_avg.first(@rolling_avg.size / 2)
      second_half = @rolling_avg.last(@rolling_avg.size / 2)
      @pnl_trend = second_half.sum { |r| r[:avg_pnl] } / second_half.size > first_half.sum { |r| r[:avg_pnl] } / first_half.size ? :improving : :declining
      @wr_trend = second_half.sum { |r| r[:win_rate] } / second_half.size > first_half.sum { |r| r[:win_rate] } / first_half.size ? :improving : :declining
    end
  end

  def analyze_behavioral_trends
    @behavior = {}

    # Trade frequency trend
    monthly_counts = {}
    @trades.each do |t|
      month = (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 7)
      next unless month
      monthly_counts[month] ||= 0
      monthly_counts[month] += 1
    end
    sorted_months = monthly_counts.sort_by { |k, _| k }
    if sorted_months.size >= 4
      first_half = sorted_months.first(sorted_months.size / 2).map(&:last)
      second_half = sorted_months.last(sorted_months.size / 2).map(&:last)
      @behavior[:frequency] = {
        trend: second_half.sum.to_f / second_half.size > first_half.sum.to_f / first_half.size ? :increasing : :decreasing,
        early_avg: (first_half.sum.to_f / first_half.size).round(1),
        recent_avg: (second_half.sum.to_f / second_half.size).round(1)
      }
    end

    # Position sizing trend
    sized_trades = @trades.select { |t| t["quantity"].to_i > 0 }
    if sized_trades.size >= 20
      sorted = sized_trades.sort_by { |t| t["exit_time"] || t["entry_time"] || "" }
      first_half = sorted.first(sorted.size / 2)
      second_half = sorted.last(sorted.size / 2)
      avg_early = first_half.sum { |t| t["quantity"].to_i } / first_half.size.to_f
      avg_recent = second_half.sum { |t| t["quantity"].to_i } / second_half.size.to_f
      @behavior[:sizing] = {
        trend: avg_recent > avg_early ? :increasing : :decreasing,
        early_avg: avg_early.round(0),
        recent_avg: avg_recent.round(0)
      }
    end

    # Symbol diversity trend
    monthly_symbols = {}
    @trades.each do |t|
      month = (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 7)
      next unless month
      monthly_symbols[month] ||= Set.new
      monthly_symbols[month] << t["symbol"]
    end
    if monthly_symbols.size >= 4
      sorted = monthly_symbols.sort_by { |k, _| k }
      first_half = sorted.first(sorted.size / 2).map { |_, v| v.size }
      second_half = sorted.last(sorted.size / 2).map { |_, v| v.size }
      @behavior[:diversity] = {
        trend: second_half.sum.to_f / second_half.size > first_half.sum.to_f / first_half.size ? :expanding : :narrowing,
        early_avg: (first_half.sum.to_f / first_half.size).round(1),
        recent_avg: (second_half.sum.to_f / second_half.size).round(1)
      }
    end

    # Journal consistency trend
    journal_by_month = {}
    @journal.each do |j|
      month = (j["date"] || j["created_at"])&.to_s&.slice(0, 7)
      next unless month
      journal_by_month[month] ||= 0
      journal_by_month[month] += 1
    end
    if journal_by_month.size >= 4
      sorted = journal_by_month.sort_by { |k, _| k }
      first_half = sorted.first(sorted.size / 2).map(&:last)
      second_half = sorted.last(sorted.size / 2).map(&:last)
      @behavior[:journaling] = {
        trend: second_half.sum.to_f / second_half.size > first_half.sum.to_f / first_half.size ? :improving : :declining,
        early_avg: (first_half.sum.to_f / first_half.size).round(1),
        recent_avg: (second_half.sum.to_f / second_half.size).round(1)
      }
    end
  end

  def analyze_seasonal_patterns
    # Day of week performance
    @dow_perf = Array.new(7) { { pnl: 0, trades: 0, wins: 0 } }
    @trades.each do |t|
      date = Date.parse(t["exit_time"] || t["entry_time"] || "") rescue nil
      next unless date
      @dow_perf[date.wday][:pnl] += t["pnl"].to_f
      @dow_perf[date.wday][:trades] += 1
      @dow_perf[date.wday][:wins] += 1 if t["pnl"].to_f > 0
    end

    @best_day = @dow_perf.each_with_index.max_by { |d, _| d[:trades] > 0 ? d[:pnl] : -Float::INFINITY }
    @worst_day = @dow_perf.each_with_index.min_by { |d, _| d[:trades] > 0 ? d[:pnl] : Float::INFINITY }

    # Hour of day performance
    @hour_perf = Array.new(24) { { pnl: 0, trades: 0, wins: 0 } }
    @trades.each do |t|
      ts = t["entry_time"]
      next unless ts.to_s.include?("T") || ts.to_s.include?(":")
      hour = Time.parse(ts).hour rescue nil
      next unless hour
      @hour_perf[hour][:pnl] += t["pnl"].to_f
      @hour_perf[hour][:trades] += 1
      @hour_perf[hour][:wins] += 1 if t["pnl"].to_f > 0
    end

    @best_hour = @hour_perf.each_with_index.max_by { |h, _| h[:trades] > 0 ? h[:pnl] : -Float::INFINITY }
    @worst_hour = @hour_perf.each_with_index.min_by { |h, _| h[:trades] > 0 ? h[:pnl] : Float::INFINITY }
  end

  def analyze_regime_changes
    return if @trades.size < 20

    sorted = @trades.sort_by { |t| t["exit_time"] || t["entry_time"] || "" }

    # Detect regime changes using rolling volatility
    @regimes = []
    window = [10, sorted.size / 10].max
    sorted.each_cons(window).each_slice(window) do |batch|
      chunk = batch.first
      pnls = chunk.map { |t| t["pnl"].to_f }
      mean = pnls.sum / pnls.size.to_f
      std = Math.sqrt(pnls.sum { |p| (p - mean) ** 2 } / pnls.size.to_f)
      wr = (chunk.count { |t| t["pnl"].to_f > 0 }.to_f / chunk.size * 100).round(1)
      total = pnls.sum

      date_range = "#{(chunk.first["exit_time"] || chunk.first["entry_time"])&.to_s&.slice(0, 10)} to #{(chunk.last["exit_time"] || chunk.last["entry_time"])&.to_s&.slice(0, 10)}"

      regime = if std > mean.abs * 2
                 "volatile"
               elsif wr >= 55 && total > 0
                 "strong"
               elsif wr <= 40 || total < 0
                 "struggling"
               else
                 "steady"
               end

      @regimes << { regime: regime, date_range: date_range, trades: chunk.size, pnl: total, win_rate: wr, volatility: std.round(2) }
    end
  end

  def generate_insights
    @insights = []

    # Performance trend
    if @pnl_trend == :improving
      @insights << { icon: "trending_up", color: "var(--positive)", text: "Your average P&L per trade is improving. Keep doing what's working." }
    elsif @pnl_trend == :declining
      @insights << { icon: "trending_down", color: "var(--negative)", text: "Your average P&L is declining. Review your recent trades for pattern changes." }
    end

    # Behavioral trends
    if @behavior[:frequency]
      if @behavior[:frequency][:trend] == :increasing
        @insights << { icon: "speed", color: "#1976d2", text: "You're trading more frequently (#{@behavior[:frequency][:early_avg]} → #{@behavior[:frequency][:recent_avg]}/month). Make sure quality isn't suffering." }
      else
        @insights << { icon: "hourglass_empty", color: "#f9a825", text: "Your trading frequency has decreased. This can be good if you're being more selective." }
      end
    end

    if @behavior[:diversity]
      if @behavior[:diversity][:trend] == :expanding
        @insights << { icon: "scatter_plot", color: "#7b1fa2", text: "You're trading more symbols (#{@behavior[:diversity][:early_avg]} → #{@behavior[:diversity][:recent_avg]}/month). Watch for overextension." }
      else
        @insights << { icon: "center_focus_strong", color: "#00796b", text: "You're focusing on fewer symbols. This specialization often improves results." }
      end
    end

    if @behavior[:journaling]
      if @behavior[:journaling][:trend] == :improving
        @insights << { icon: "edit_note", color: "var(--positive)", text: "Journal consistency improving. Discipline in journaling correlates with trading discipline." }
      else
        @insights << { icon: "edit_off", color: "var(--negative)", text: "You're journaling less frequently. Consider re-establishing the habit." }
      end
    end

    # Seasonal
    day_names = %w[Sunday Monday Tuesday Wednesday Thursday Friday Saturday]
    if @best_day && @best_day[0][:trades] > 0
      @insights << { icon: "event", color: "#1565c0", text: "Best performance day: #{day_names[@best_day[1]]} (#{number_to_currency(@best_day[0][:pnl])} total)." }
    end

    if @worst_day && @worst_day[0][:trades] > 0 && @worst_day[0][:pnl] < 0
      @insights << { icon: "event_busy", color: "var(--negative)", text: "Worst day: #{day_names[@worst_day[1]]} (#{number_to_currency(@worst_day[0][:pnl])}). Consider reducing exposure on #{day_names[@worst_day[1]]}s." }
    end
  end

  def avg_hold_time(trades)
    durations = trades.filter_map do |t|
      next unless t["entry_time"] && t["exit_time"]
      entry = Time.parse(t["entry_time"]) rescue nil
      exit_t = Time.parse(t["exit_time"]) rescue nil
      next unless entry && exit_t
      (exit_t - entry) / 60.0 # minutes
    end
    return "N/A" if durations.empty?
    avg = durations.sum / durations.size
    if avg < 60
      "#{avg.round(0)}m"
    elsif avg < 1440
      "#{(avg / 60).round(1)}h"
    else
      "#{(avg / 1440).round(1)}d"
    end
  end
end

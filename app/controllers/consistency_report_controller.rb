class ConsistencyReportController < ApplicationController
  include ApiConnected

  def show
    trades_thread = Thread.new do
      fetch_all_trades
    rescue => e
      Rails.logger.error("consistency trades: #{e.message}")
      []
    end

    journal_thread = Thread.new do
      result = api_client.journal_entries(per_page: 500)
      extract_list(result, "journal_entries")
    rescue => e
      Rails.logger.error("consistency journal: #{e.message}")
      []
    end

    streaks_thread = Thread.new do
      api_client.streaks
    rescue => e
      Rails.logger.error("consistency streaks: #{e.message}")
      {}
    end

    trades = trades_thread.value || []
    journal = journal_thread.value || []
    streaks = streaks_thread.value || {}

    closed = trades.select { |t| t["status"] == "closed" || t["exit_price"].present? }
                   .sort_by { |t| t["closed_at"] || t["created_at"] || "" }

    # 1. Entry Time Consistency
    entry_hours = closed.map { |t| parse_hour(t["created_at"]) }.compact
    @entry_time = compute_consistency(entry_hours)

    # 2. Position Sizing Consistency
    sizes = closed.map { |t| (t["entry_price"].to_f * (t["quantity"] || 1).to_f).round(2) }.select(&:positive?)
    @sizing = compute_consistency(sizes)

    # 3. Hold Time Consistency (minutes)
    hold_times = closed.map { |t| compute_hold_time(t) }.compact
    @hold_time = compute_consistency(hold_times)

    # 4. Journaling Discipline
    trade_dates = closed.map { |t| (t["closed_at"] || t["created_at"]).to_s.slice(0, 10) }.uniq
    journal_dates = journal.map { |j| (j["date"] || j["created_at"]).to_s.slice(0, 10) }.uniq
    journaled_trade_days = trade_dates.count { |d| journal_dates.include?(d) }
    @journal_rate = trade_dates.any? ? (journaled_trade_days.to_f / trade_dates.length * 100).round(1) : 0

    # 5. Stop-Loss Usage
    with_stop = closed.count { |t| t["stop_loss"].present? && t["stop_loss"].to_f > 0 }
    @stop_loss_rate = closed.any? ? (with_stop.to_f / closed.length * 100).round(1) : 0

    # 6. Trade Review Rate
    reviewed = closed.count { |t| t["reviewed"].present? || t["review_rating"].present? }
    @review_rate = closed.any? ? (reviewed.to_f / closed.length * 100).round(1) : 0

    # 7. Plan Adherence (trades with a plan/playbook)
    with_plan = closed.count { |t| t["playbook_id"].present? || t["trade_plan_id"].present? }
    @plan_rate = closed.any? ? (with_plan.to_f / closed.length * 100).round(1) : 0

    # 8. Daily Trade Count Consistency
    daily_counts = closed.group_by { |t| (t["closed_at"] || t["created_at"]).to_s.slice(0, 10) }
                         .map { |_, v| v.length }
    @daily_count = compute_consistency(daily_counts)

    # 9. Win Rate Stability (rolling 10-trade window)
    @rolling_win_rates = []
    if closed.length >= 10
      (0..closed.length - 10).each do |i|
        window = closed[i, 10]
        wins = window.count { |t| t["pnl"].to_f > 0 }
        @rolling_win_rates << (wins.to_f / 10 * 100).round(1)
      end
    end
    @win_rate_stability = @rolling_win_rates.any? ? compute_consistency(@rolling_win_rates) : { cv: 0, score: 50 }

    # Overall Consistency Score
    scores = []
    scores << @entry_time[:score] if entry_hours.any?
    scores << @sizing[:score] if sizes.any?
    scores << @hold_time[:score] if hold_times.any?
    scores << @journal_rate
    scores << @stop_loss_rate
    scores << @review_rate
    scores << @plan_rate
    scores << @daily_count[:score] if daily_counts.any?
    scores << @win_rate_stability[:score]

    @overall_score = scores.any? ? (scores.sum / scores.length).round(0) : 0
    @trade_count = closed.length
    @dimension_scores = build_dimension_scores
  end

  private

  def fetch_all_trades
    all = []
    page = 1
    loop do
      result = api_client.trades(page: page, per_page: 200, sort: "closed_at", direction: "asc")
      batch = result.is_a?(Hash) ? (result["trades"] || result["data"] || []) : Array(result)
      break if batch.empty?
      all.concat(batch)
      break if batch.length < 200
      page += 1
    end
    all
  end

  def extract_list(data, key)
    if data.is_a?(Hash)
      data[key] || data["data"] || []
    elsif data.is_a?(Array)
      data
    else
      []
    end
  end

  def parse_hour(timestamp)
    return nil unless timestamp.present?
    time = Time.parse(timestamp.to_s) rescue nil
    time&.hour
  end

  def compute_hold_time(trade)
    opened = trade["created_at"] || trade["opened_at"]
    closed = trade["closed_at"]
    return nil unless opened.present? && closed.present?
    o = Time.parse(opened.to_s) rescue nil
    c = Time.parse(closed.to_s) rescue nil
    return nil unless o && c
    ((c - o) / 60.0).round(0).to_i  # minutes
  end

  def compute_consistency(values)
    return { mean: 0, std: 0, cv: 0, score: 50 } if values.empty?

    mean = values.sum.to_f / values.length
    variance = values.sum { |v| (v - mean) ** 2 }.to_f / values.length
    std = Math.sqrt(variance)
    cv = mean != 0 ? (std / mean.abs * 100).round(1) : 0

    # Lower CV = more consistent = higher score
    # CV of 0 = 100, CV of 100+ = 0
    score = [100 - cv, 0].max.round(0)

    { mean: mean.round(2), std: std.round(2), cv: cv, score: score }
  end

  def build_dimension_scores
    [
      { name: "Entry Timing", score: @entry_time[:score], icon: "schedule", detail: "CV: #{@entry_time[:cv]}%" },
      { name: "Position Sizing", score: @sizing[:score], icon: "straighten", detail: "CV: #{@sizing[:cv]}%" },
      { name: "Hold Time", score: @hold_time[:score], icon: "timer", detail: "CV: #{@hold_time[:cv]}%" },
      { name: "Journaling", score: @journal_rate.round(0), icon: "edit_note", detail: "#{@journal_rate}% of trade days" },
      { name: "Stop-Losses", score: @stop_loss_rate.round(0), icon: "shield", detail: "#{@stop_loss_rate}% of trades" },
      { name: "Trade Review", score: @review_rate.round(0), icon: "rate_review", detail: "#{@review_rate}% reviewed" },
      { name: "Plan Adherence", score: @plan_rate.round(0), icon: "assignment", detail: "#{@plan_rate}% with playbook" },
      { name: "Daily Volume", score: @daily_count[:score], icon: "bar_chart", detail: "CV: #{@daily_count[:cv]}%" },
      { name: "Win Rate Stability", score: @win_rate_stability[:score], icon: "trending_flat", detail: "CV: #{@win_rate_stability[:cv]}%" }
    ]
  end
end

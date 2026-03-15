class PerformanceAttributionController < ApplicationController
  include ApiConnected

  def show
    trades_thread = Thread.new do
      fetch_all_trades
    rescue => e
      Rails.logger.error("perf_attribution trades: #{e.message}")
      []
    end

    stats_thread = Thread.new do
      api_client.overview
    rescue => e
      Rails.logger.error("perf_attribution stats: #{e.message}")
      {}
    end

    trades = trades_thread.value || []
    stats = stats_thread.value || {}

    closed = trades.select { |t| t["status"] == "closed" || t["exit_price"].present? }

    @total_pnl = closed.sum { |t| t["pnl"].to_f }

    @by_symbol = attribute_by(closed, "symbol")
    @by_side = attribute_by(closed, "side")
    @by_asset_class = attribute_by(closed, "asset_class")
    @by_tag = attribute_by_tags(closed)
    @by_time_of_day = attribute_by_time(closed)
    @by_day_of_week = attribute_by_day(closed)
    @by_month = attribute_by_month(closed)
    @by_hold_time = attribute_by_hold_time(closed)

    @top_contributors = @by_symbol.sort_by { |s| -s[:total_pnl] }.first(5)
    @top_detractors = @by_symbol.sort_by { |s| s[:total_pnl] }.first(5)

    @concentration = compute_concentration(@by_symbol)
    @summary = build_summary(stats)
  end

  private

  def fetch_all_trades
    all = []
    page = 1
    loop do
      result = api_client.trades(page: page, per_page: 200)
      batch = result.is_a?(Hash) ? (result["trades"] || result["data"] || []) : Array(result)
      break if batch.empty?
      all.concat(batch)
      break if batch.length < 200
      page += 1
    end
    all
  end

  def attribute_by(trades, field)
    trades.group_by { |t| t[field] || "Unknown" }.map do |key, group|
      pnls = group.map { |t| t["pnl"].to_f }
      wins = pnls.count { |p| p > 0 }
      {
        name: key,
        count: group.length,
        total_pnl: pnls.sum.round(2),
        avg_pnl: (pnls.sum / [pnls.length, 1].max).round(2),
        win_rate: (wins.to_f / [pnls.length, 1].max * 100).round(1),
        best: pnls.max&.round(2) || 0,
        worst: pnls.min&.round(2) || 0,
        pnl_pct: @total_pnl != 0 ? (pnls.sum / @total_pnl.abs * 100).round(1) : 0
      }
    end.sort_by { |a| -a[:total_pnl] }
  end

  def attribute_by_tags(trades)
    tag_groups = Hash.new { |h, k| h[k] = [] }
    trades.each do |t|
      tags = t["tags"] || t["tag_list"] || []
      tags = tags.split(",").map(&:strip) if tags.is_a?(String)
      tags = ["Untagged"] if tags.empty?
      tags.each { |tag| tag_groups[tag] << t }
    end

    tag_groups.map do |tag, group|
      pnls = group.map { |t| t["pnl"].to_f }
      wins = pnls.count { |p| p > 0 }
      {
        name: tag,
        count: group.length,
        total_pnl: pnls.sum.round(2),
        avg_pnl: (pnls.sum / [pnls.length, 1].max).round(2),
        win_rate: (wins.to_f / [pnls.length, 1].max * 100).round(1),
        pnl_pct: @total_pnl != 0 ? (pnls.sum / @total_pnl.abs * 100).round(1) : 0
      }
    end.sort_by { |a| -a[:total_pnl] }
  end

  def attribute_by_time(trades)
    buckets = { "Pre-Market (4-9:30)" => [], "Morning (9:30-11:30)" => [], "Midday (11:30-14)" => [], "Afternoon (14-16)" => [], "After Hours (16+)" => [] }
    trades.each do |t|
      time_str = t["entry_time"] || t["opened_at"] || t["created_at"]
      next unless time_str
      hour = Time.parse(time_str).hour rescue next
      bucket = case hour
               when 4..9 then "Pre-Market (4-9:30)"
               when 10..11 then "Morning (9:30-11:30)"
               when 12..13 then "Midday (11:30-14)"
               when 14..15 then "Afternoon (14-16)"
               else "After Hours (16+)"
               end
      buckets[bucket] << t
    end

    buckets.map do |name, group|
      pnls = group.map { |t| t["pnl"].to_f }
      wins = pnls.count { |p| p > 0 }
      {
        name: name,
        count: group.length,
        total_pnl: pnls.sum.round(2),
        avg_pnl: (pnls.sum / [pnls.length, 1].max).round(2),
        win_rate: group.any? ? (wins.to_f / pnls.length * 100).round(1) : 0,
        pnl_pct: @total_pnl != 0 ? (pnls.sum / @total_pnl.abs * 100).round(1) : 0
      }
    end.reject { |b| b[:count] == 0 }
  end

  def attribute_by_day(trades)
    days = %w[Monday Tuesday Wednesday Thursday Friday Saturday Sunday]
    trades.group_by do |t|
      date = Date.parse(t["closed_at"] || t["created_at"] || "2000-01-01") rescue Date.today
      date.strftime("%A")
    end.map do |day, group|
      pnls = group.map { |t| t["pnl"].to_f }
      wins = pnls.count { |p| p > 0 }
      {
        name: day,
        count: group.length,
        total_pnl: pnls.sum.round(2),
        avg_pnl: (pnls.sum / [pnls.length, 1].max).round(2),
        win_rate: (wins.to_f / [pnls.length, 1].max * 100).round(1),
        pnl_pct: @total_pnl != 0 ? (pnls.sum / @total_pnl.abs * 100).round(1) : 0
      }
    end.sort_by { |d| days.index(d[:name]) || 99 }
  end

  def attribute_by_month(trades)
    trades.group_by do |t|
      date = Date.parse(t["closed_at"] || t["created_at"] || "2000-01") rescue Date.today
      date.strftime("%Y-%m")
    end.map do |month, group|
      pnls = group.map { |t| t["pnl"].to_f }
      wins = pnls.count { |p| p > 0 }
      {
        name: month,
        count: group.length,
        total_pnl: pnls.sum.round(2),
        avg_pnl: (pnls.sum / [pnls.length, 1].max).round(2),
        win_rate: (wins.to_f / [pnls.length, 1].max * 100).round(1),
        pnl_pct: @total_pnl != 0 ? (pnls.sum / @total_pnl.abs * 100).round(1) : 0
      }
    end.sort_by { |m| m[:name] }
  end

  def attribute_by_hold_time(trades)
    buckets = { "Scalp (<5min)" => [], "Day Trade (5min-1hr)" => [], "Swing (1hr-1d)" => [], "Position (1d-1w)" => [], "Long Term (1w+)" => [] }
    trades.each do |t|
      minutes = t["hold_time_minutes"]&.to_f || begin
        opened = Time.parse(t["opened_at"] || t["created_at"] || "") rescue nil
        closed = Time.parse(t["closed_at"] || "") rescue nil
        opened && closed ? ((closed - opened) / 60) : nil
      end
      next unless minutes
      bucket = case minutes
               when 0..5 then "Scalp (<5min)"
               when 5..60 then "Day Trade (5min-1hr)"
               when 60..1440 then "Swing (1hr-1d)"
               when 1440..10080 then "Position (1d-1w)"
               else "Long Term (1w+)"
               end
      buckets[bucket] << t
    end

    buckets.map do |name, group|
      pnls = group.map { |t| t["pnl"].to_f }
      wins = pnls.count { |p| p > 0 }
      {
        name: name,
        count: group.length,
        total_pnl: pnls.sum.round(2),
        avg_pnl: group.any? ? (pnls.sum / pnls.length).round(2) : 0,
        win_rate: group.any? ? (wins.to_f / pnls.length * 100).round(1) : 0,
        pnl_pct: @total_pnl != 0 ? (pnls.sum / @total_pnl.abs * 100).round(1) : 0
      }
    end.reject { |b| b[:count] == 0 }
  end

  def compute_concentration(by_symbol)
    return { hhi: 0, top_3_pct: 0, diversified: true } if by_symbol.empty?

    total_abs = by_symbol.sum { |s| s[:total_pnl].abs }
    return { hhi: 0, top_3_pct: 0, diversified: true } if total_abs == 0

    shares = by_symbol.map { |s| (s[:total_pnl].abs / total_abs * 100) }
    hhi = shares.sum { |s| s ** 2 }.round(0)
    top_3 = shares.sort.reverse.first(3).sum.round(1)

    { hhi: hhi, top_3_pct: top_3, diversified: hhi < 2500, symbol_count: by_symbol.length }
  end

  def build_summary(stats)
    {
      total_pnl: @total_pnl.round(2),
      win_rate: stats.is_a?(Hash) ? stats["win_rate"]&.to_f&.round(1) : nil,
      total_trades: stats.is_a?(Hash) ? stats["total_trades"].to_i : 0,
      profit_factor: stats.is_a?(Hash) ? stats["profit_factor"]&.to_f&.round(2) : nil
    }
  end
end

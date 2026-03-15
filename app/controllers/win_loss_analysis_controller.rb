class WinLossAnalysisController < ApplicationController
  include ApiConnected

  def show
    trades_thread = Thread.new do
      fetch_all_trades
    rescue => e
      Rails.logger.error("win_loss_analysis trades: #{e.message}")
      []
    end

    trades = trades_thread.value || []
    closed = trades.select { |t| t["status"] == "closed" || t["exit_price"].present? }

    winners = closed.select { |t| t["pnl"].to_f > 0 }
    losers = closed.select { |t| t["pnl"].to_f <= 0 }

    @summary = build_summary(winners, losers)
    @win_profile = build_profile(winners, "Winning")
    @loss_profile = build_profile(losers, "Losing")
    @comparisons = build_comparisons(winners, losers)
    @time_analysis = analyze_time_patterns(winners, losers)
    @size_analysis = analyze_size_patterns(winners, losers)
    @hold_analysis = analyze_hold_patterns(winners, losers)
    @edge_factors = find_edge_factors(winners, losers)
    @recent_pattern = recent_wl_pattern(closed.first(30))
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

  def build_summary(winners, losers)
    total = winners.length + losers.length
    win_pnls = winners.map { |t| t["pnl"].to_f }
    loss_pnls = losers.map { |t| t["pnl"].to_f }

    {
      total: total,
      wins: winners.length,
      losses: losers.length,
      win_rate: total > 0 ? (winners.length.to_f / total * 100).round(1) : 0,
      avg_win: win_pnls.any? ? (win_pnls.sum / win_pnls.length).round(2) : 0,
      avg_loss: loss_pnls.any? ? (loss_pnls.sum / loss_pnls.length).round(2) : 0,
      largest_win: win_pnls.max&.round(2) || 0,
      largest_loss: loss_pnls.min&.round(2) || 0,
      total_win_pnl: win_pnls.sum.round(2),
      total_loss_pnl: loss_pnls.sum.round(2),
      payoff_ratio: loss_pnls.any? && loss_pnls.sum != 0 ? ((win_pnls.any? ? win_pnls.sum / win_pnls.length : 0) / (loss_pnls.sum / loss_pnls.length).abs).round(2) : 0,
      expectancy: total > 0 ? ((win_pnls.sum + loss_pnls.sum) / total).round(2) : 0
    }
  end

  def build_profile(trades, label)
    return { label: label, count: 0, symbols: [], avg_hold: 0 } if trades.empty?

    pnls = trades.map { |t| t["pnl"].to_f }
    symbols = trades.group_by { |t| t["symbol"] }.transform_values(&:length).sort_by { |_, v| -v }.first(5)
    sides = trades.group_by { |t| t["side"] || "unknown" }.transform_values(&:length)

    hold_times = trades.filter_map do |t|
      opened = Time.parse(t["opened_at"] || t["created_at"] || "") rescue nil
      closed_at = Time.parse(t["closed_at"] || "") rescue nil
      opened && closed_at ? ((closed_at - opened) / 60).round : nil
    end

    {
      label: label,
      count: trades.length,
      avg_pnl: (pnls.sum / pnls.length).round(2),
      median_pnl: median(pnls).round(2),
      top_symbols: symbols.map { |s, c| { name: s, count: c } },
      sides: sides,
      avg_hold_minutes: hold_times.any? ? (hold_times.sum / hold_times.length).round : 0,
      median_hold_minutes: hold_times.any? ? median(hold_times).round : 0
    }
  end

  def build_comparisons(winners, losers)
    dims = []

    # By symbol
    w_syms = winners.group_by { |t| t["symbol"] }
    l_syms = losers.group_by { |t| t["symbol"] }
    all_syms = (w_syms.keys + l_syms.keys).uniq
    sym_data = all_syms.map do |s|
      w = w_syms[s]&.length || 0
      l = l_syms[s]&.length || 0
      total = w + l
      { name: s, wins: w, losses: l, win_rate: total > 0 ? (w.to_f / total * 100).round(1) : 0 }
    end.sort_by { |s| -s[:win_rate] }
    dims << { title: "By Symbol", data: sym_data.first(10) }

    # By side
    w_sides = winners.group_by { |t| t["side"] || "unknown" }
    l_sides = losers.group_by { |t| t["side"] || "unknown" }
    all_sides = (w_sides.keys + l_sides.keys).uniq
    side_data = all_sides.map do |s|
      w = w_sides[s]&.length || 0
      l = l_sides[s]&.length || 0
      total = w + l
      { name: s.capitalize, wins: w, losses: l, win_rate: total > 0 ? (w.to_f / total * 100).round(1) : 0 }
    end
    dims << { title: "By Side", data: side_data }

    # By asset class
    w_ac = winners.group_by { |t| t["asset_class"] || "Unknown" }
    l_ac = losers.group_by { |t| t["asset_class"] || "Unknown" }
    all_ac = (w_ac.keys + l_ac.keys).uniq
    ac_data = all_ac.map do |a|
      w = w_ac[a]&.length || 0
      l = l_ac[a]&.length || 0
      total = w + l
      { name: a.capitalize, wins: w, losses: l, win_rate: total > 0 ? (w.to_f / total * 100).round(1) : 0 }
    end
    dims << { title: "By Asset Class", data: ac_data }

    dims
  end

  def analyze_time_patterns(winners, losers)
    w_hours = winners.filter_map { |t| Time.parse(t["opened_at"] || t["created_at"] || "").hour rescue nil }
    l_hours = losers.filter_map { |t| Time.parse(t["opened_at"] || t["created_at"] || "").hour rescue nil }

    (6..20).map do |h|
      w = w_hours.count(h)
      l = l_hours.count(h)
      total = w + l
      { hour: h, label: "#{h}:00", wins: w, losses: l, win_rate: total > 0 ? (w.to_f / total * 100).round(1) : 0 }
    end.select { |h| h[:wins] + h[:losses] > 0 }
  end

  def analyze_size_patterns(winners, losers)
    buckets = { "Small" => 0..1000, "Medium" => 1000..5000, "Large" => 5000..20000, "Very Large" => 20000..Float::INFINITY }
    buckets.map do |label, range|
      w = winners.count { |t| range.include?((t["quantity"].to_f * t["entry_price"].to_f).abs) }
      l = losers.count { |t| range.include?((t["quantity"].to_f * t["entry_price"].to_f).abs) }
      total = w + l
      { name: label, wins: w, losses: l, win_rate: total > 0 ? (w.to_f / total * 100).round(1) : 0, total: total }
    end.select { |b| b[:total] > 0 }
  end

  def analyze_hold_patterns(winners, losers)
    buckets = { "< 5 min" => 0..5, "5-30 min" => 5..30, "30-60 min" => 30..60, "1-4 hrs" => 60..240, "4+ hrs" => 240..Float::INFINITY }

    buckets.map do |label, range|
      w = winners.count do |t|
        mins = hold_minutes(t)
        mins && range.include?(mins)
      end
      l = losers.count do |t|
        mins = hold_minutes(t)
        mins && range.include?(mins)
      end
      total = w + l
      { name: label, wins: w, losses: l, win_rate: total > 0 ? (w.to_f / total * 100).round(1) : 0, total: total }
    end.select { |b| b[:total] > 0 }
  end

  def hold_minutes(t)
    opened = Time.parse(t["opened_at"] || t["created_at"] || "") rescue nil
    closed_at = Time.parse(t["closed_at"] || "") rescue nil
    opened && closed_at ? ((closed_at - opened) / 60).round : nil
  end

  def find_edge_factors(winners, losers)
    factors = []

    # Check if journaled trades perform better
    w_journaled = winners.count { |t| t["journal_entry_id"].present? || t["reviewed"].to_s == "true" }
    l_journaled = losers.count { |t| t["journal_entry_id"].present? || t["reviewed"].to_s == "true" }
    if w_journaled + l_journaled > 5
      wr = ((w_journaled.to_f / (w_journaled + l_journaled)) * 100).round(1)
      factors << { factor: "Reviewed/Journaled Trades", win_rate: wr, sample: w_journaled + l_journaled, positive: wr > 50 }
    end

    # Check if trades with stop losses perform better
    w_stops = winners.count { |t| t["stop_loss"].present? }
    l_stops = losers.count { |t| t["stop_loss"].present? }
    if w_stops + l_stops > 5
      wr = ((w_stops.to_f / (w_stops + l_stops)) * 100).round(1)
      factors << { factor: "Trades with Stop Loss", win_rate: wr, sample: w_stops + l_stops, positive: wr > 50 }
    end

    # Best symbol win rate
    @comparisons.first[:data].first(3).each do |sym|
      factors << { factor: "#{sym[:name]} trades", win_rate: sym[:win_rate], sample: sym[:wins] + sym[:losses], positive: sym[:win_rate] > 55 }
    end if @comparisons.first && @comparisons.first[:data].any?

    factors
  end

  def recent_wl_pattern(trades)
    trades.first(30).map do |t|
      pnl = t["pnl"].to_f
      { symbol: t["symbol"], pnl: pnl.round(2), win: pnl > 0 }
    end
  end

  def median(arr)
    return 0 if arr.empty?
    sorted = arr.sort
    mid = sorted.length / 2
    sorted.length.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
  end
end

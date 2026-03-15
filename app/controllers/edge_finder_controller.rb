class EdgeFinderController < ApplicationController
  before_action :require_api_connection

  include ActionView::Helpers::NumberHelper

  def show
    trade_result = api_client.trades(per_page: 1000)
    all_trades = trade_result.is_a?(Hash) ? (trade_result["trades"] || []) : Array(trade_result)
    all_trades = all_trades.select { |t| t.is_a?(Hash) }
    @trades = all_trades.select { |t| t["status"]&.downcase == "closed" && t["pnl"].present? }

    return if @trades.empty?

    @edges = []
    @anti_edges = []

    # Pre-compute shared data
    wins = @trades.select { |t| t["pnl"].to_f > 0 }
    total_count = @trades.count
    overall_win_rate = total_count > 0 ? (wins.count.to_f / total_count * 100).round(1) : 0
    overall_avg_pnl = total_count > 0 ? (@trades.sum { |t| t["pnl"].to_f } / total_count).round(2) : 0

    # Average position size for bucketing
    position_sizes = @trades.filter_map { |t|
      entry = t["entry_price"].to_f
      qty = t["quantity"].to_f
      entry > 0 && qty > 0 ? entry * qty : nil
    }
    avg_position_size = position_sizes.any? ? position_sizes.sum / position_sizes.count : 0

    # ── By Symbol ──
    symbol_groups = @trades.group_by { |t| (t["symbol"] || "Unknown").upcase }
    symbol_groups.each do |symbol, trades|
      stats = compute_edge_stats(trades)
      next unless stats[:trade_count] >= 3
      significant = stats[:trade_count] >= 10 && stats[:win_rate] > 55
      edge = {
        category: "Symbol",
        name: symbol,
        description: "#{symbol} trades",
        win_rate: stats[:win_rate],
        avg_pnl: stats[:avg_pnl],
        total_pnl: stats[:total_pnl],
        trade_count: stats[:trade_count],
        significant: significant,
        edge_score: compute_edge_score(stats, overall_win_rate, overall_avg_pnl)
      }
      if stats[:win_rate] < 40 && stats[:trade_count] >= 5
        @anti_edges << edge
      elsif significant
        @edges << edge
      end
    end

    # ── By Time of Day ──
    hour_groups = @trades.group_by { |t|
      time_str = t["entry_time"].to_s
      hour = parse_hour(time_str)
      hour ? format_hour(hour) : nil
    }.reject { |k, _| k.nil? }
    hour_groups.each do |hour_label, trades|
      stats = compute_edge_stats(trades)
      next unless stats[:trade_count] >= 3
      significant = stats[:trade_count] >= 10 && stats[:win_rate] > 55
      edge = {
        category: "Time of Day",
        name: hour_label,
        description: "Trades entered at #{hour_label}",
        win_rate: stats[:win_rate],
        avg_pnl: stats[:avg_pnl],
        total_pnl: stats[:total_pnl],
        trade_count: stats[:trade_count],
        significant: significant,
        edge_score: compute_edge_score(stats, overall_win_rate, overall_avg_pnl)
      }
      if stats[:win_rate] < 40 && stats[:trade_count] >= 5
        @anti_edges << edge
      elsif significant
        @edges << edge
      end
    end

    # ── By Day of Week ──
    day_names = %w[Sunday Monday Tuesday Wednesday Thursday Friday Saturday]
    day_groups = @trades.group_by { |t|
      date_str = (t["entry_time"] || t["exit_time"]).to_s.slice(0, 10)
      begin
        Date.parse(date_str).wday
      rescue
        nil
      end
    }.reject { |k, _| k.nil? }
    day_groups.each do |wday, trades|
      stats = compute_edge_stats(trades)
      next unless stats[:trade_count] >= 3
      significant = stats[:trade_count] >= 10 && stats[:win_rate] > 55
      edge = {
        category: "Day of Week",
        name: day_names[wday],
        description: "#{day_names[wday]} trades",
        win_rate: stats[:win_rate],
        avg_pnl: stats[:avg_pnl],
        total_pnl: stats[:total_pnl],
        trade_count: stats[:trade_count],
        significant: significant,
        edge_score: compute_edge_score(stats, overall_win_rate, overall_avg_pnl)
      }
      if stats[:win_rate] < 40 && stats[:trade_count] >= 5
        @anti_edges << edge
      elsif significant
        @edges << edge
      end
    end

    # ── By Position Size ──
    if avg_position_size > 0
      size_groups = @trades.group_by { |t|
        entry = t["entry_price"].to_f
        qty = t["quantity"].to_f
        size = entry > 0 && qty > 0 ? entry * qty : nil
        next nil unless size
        ratio = size / avg_position_size
        if ratio < 0.5
          "Small"
        elsif ratio < 1.5
          "Medium"
        else
          "Large"
        end
      }.reject { |k, _| k.nil? }
      size_groups.each do |bucket, trades|
        stats = compute_edge_stats(trades)
        next unless stats[:trade_count] >= 3
        significant = stats[:trade_count] >= 10 && stats[:win_rate] > 55
        edge = {
          category: "Position Size",
          name: "#{bucket} Positions",
          description: "#{bucket}-sized positions relative to average",
          win_rate: stats[:win_rate],
          avg_pnl: stats[:avg_pnl],
          total_pnl: stats[:total_pnl],
          trade_count: stats[:trade_count],
          significant: significant,
          edge_score: compute_edge_score(stats, overall_win_rate, overall_avg_pnl)
        }
        if stats[:win_rate] < 40 && stats[:trade_count] >= 5
          @anti_edges << edge
        elsif significant
          @edges << edge
        end
      end
    end

    # ── By Hold Duration ──
    duration_groups = @trades.group_by { |t|
      entry_str = t["entry_time"].to_s
      exit_str = t["exit_time"].to_s
      next nil if entry_str.empty? || exit_str.empty?
      begin
        entry_t = Time.parse(entry_str)
        exit_t = Time.parse(exit_str)
        minutes = ((exit_t - entry_t) / 60.0).abs
        if minutes < 30
          "Scalp (<30min)"
        elsif minutes < 1440
          "Day Trade"
        elsif minutes < 7200
          "Swing (1-5 days)"
        else
          "Position (5+ days)"
        end
      rescue
        nil
      end
    }.reject { |k, _| k.nil? }
    duration_groups.each do |bucket, trades|
      stats = compute_edge_stats(trades)
      next unless stats[:trade_count] >= 3
      significant = stats[:trade_count] >= 10 && stats[:win_rate] > 55
      edge = {
        category: "Hold Duration",
        name: bucket,
        description: "#{bucket} trades",
        win_rate: stats[:win_rate],
        avg_pnl: stats[:avg_pnl],
        total_pnl: stats[:total_pnl],
        trade_count: stats[:trade_count],
        significant: significant,
        edge_score: compute_edge_score(stats, overall_win_rate, overall_avg_pnl)
      }
      if stats[:win_rate] < 40 && stats[:trade_count] >= 5
        @anti_edges << edge
      elsif significant
        @edges << edge
      end
    end

    # ── By Trade Direction ──
    direction_groups = @trades.group_by { |t|
      side = (t["side"] || t["direction"] || "").downcase
      if side.include?("long") || side.include?("buy")
        "Long"
      elsif side.include?("short") || side.include?("sell")
        "Short"
      else
        nil
      end
    }.reject { |k, _| k.nil? }
    direction_groups.each do |direction, trades|
      stats = compute_edge_stats(trades)
      next unless stats[:trade_count] >= 3
      significant = stats[:trade_count] >= 10 && stats[:win_rate] > 55
      edge = {
        category: "Direction",
        name: "#{direction} Trades",
        description: "#{direction} side trades",
        win_rate: stats[:win_rate],
        avg_pnl: stats[:avg_pnl],
        total_pnl: stats[:total_pnl],
        trade_count: stats[:trade_count],
        significant: significant,
        edge_score: compute_edge_score(stats, overall_win_rate, overall_avg_pnl)
      }
      if stats[:win_rate] < 40 && stats[:trade_count] >= 5
        @anti_edges << edge
      elsif significant
        @edges << edge
      end
    end

    # ── By Setup/Tag ──
    tag_trades = @trades.select { |t| t["tags"].is_a?(Array) && t["tags"].any? }
    tag_groups = {}
    tag_trades.each do |t|
      t["tags"].each do |tag|
        tag_name = tag.is_a?(Hash) ? (tag["name"] || tag["label"] || tag.to_s) : tag.to_s
        next if tag_name.strip.empty?
        tag_groups[tag_name] ||= []
        tag_groups[tag_name] << t
      end
    end
    tag_groups.each do |tag_name, trades|
      stats = compute_edge_stats(trades)
      next unless stats[:trade_count] >= 3
      significant = stats[:trade_count] >= 10 && stats[:win_rate] > 55
      edge = {
        category: "Setup/Tag",
        name: tag_name,
        description: "Tagged: #{tag_name}",
        win_rate: stats[:win_rate],
        avg_pnl: stats[:avg_pnl],
        total_pnl: stats[:total_pnl],
        trade_count: stats[:trade_count],
        significant: significant,
        edge_score: compute_edge_score(stats, overall_win_rate, overall_avg_pnl)
      }
      if stats[:win_rate] < 40 && stats[:trade_count] >= 5
        @anti_edges << edge
      elsif significant
        @edges << edge
      end
    end

    # ── By Month ──
    month_names = %w[_ January February March April May June July August September October November December]
    month_groups = @trades.group_by { |t|
      date_str = (t["entry_time"] || t["exit_time"]).to_s.slice(0, 10)
      begin
        Date.parse(date_str).month
      rescue
        nil
      end
    }.reject { |k, _| k.nil? }
    month_groups.each do |month_num, trades|
      stats = compute_edge_stats(trades)
      next unless stats[:trade_count] >= 3
      significant = stats[:trade_count] >= 10 && stats[:win_rate] > 55
      edge = {
        category: "Month",
        name: month_names[month_num],
        description: "Trades in #{month_names[month_num]}",
        win_rate: stats[:win_rate],
        avg_pnl: stats[:avg_pnl],
        total_pnl: stats[:total_pnl],
        trade_count: stats[:trade_count],
        significant: significant,
        edge_score: compute_edge_score(stats, overall_win_rate, overall_avg_pnl)
      }
      if stats[:win_rate] < 40 && stats[:trade_count] >= 5
        @anti_edges << edge
      elsif significant
        @edges << edge
      end
    end

    # ── By Stop Loss Usage ──
    stop_groups = @trades.group_by { |t|
      t["stop_loss"].to_f > 0 ? "With Stop Loss" : "Without Stop Loss"
    }
    stop_groups.each do |label, trades|
      stats = compute_edge_stats(trades)
      next unless stats[:trade_count] >= 3
      significant = stats[:trade_count] >= 10 && stats[:win_rate] > 55
      edge = {
        category: "Stop Loss",
        name: label,
        description: "Trades #{label.downcase}",
        win_rate: stats[:win_rate],
        avg_pnl: stats[:avg_pnl],
        total_pnl: stats[:total_pnl],
        trade_count: stats[:trade_count],
        significant: significant,
        edge_score: compute_edge_score(stats, overall_win_rate, overall_avg_pnl)
      }
      if stats[:win_rate] < 40 && stats[:trade_count] >= 5
        @anti_edges << edge
      elsif significant
        @edges << edge
      end
    end

    # ── By Risk/Reward Ratio ──
    rr_groups = @trades.group_by { |t|
      entry = t["entry_price"].to_f
      stop = t["stop_loss"].to_f
      target = t["take_profit"].to_f
      next nil unless entry > 0 && stop > 0 && target > 0
      risk = (entry - stop).abs
      reward = (target - entry).abs
      next nil unless risk > 0
      rr = reward / risk
      if rr < 1
        "R:R < 1"
      elsif rr < 2
        "R:R 1-2"
      elsif rr < 3
        "R:R 2-3"
      else
        "R:R 3+"
      end
    }.reject { |k, _| k.nil? }
    rr_groups.each do |bucket, trades|
      stats = compute_edge_stats(trades)
      next unless stats[:trade_count] >= 3
      significant = stats[:trade_count] >= 10 && stats[:win_rate] > 55
      edge = {
        category: "Risk/Reward",
        name: bucket,
        description: "Trades with #{bucket}",
        win_rate: stats[:win_rate],
        avg_pnl: stats[:avg_pnl],
        total_pnl: stats[:total_pnl],
        trade_count: stats[:trade_count],
        significant: significant,
        edge_score: compute_edge_score(stats, overall_win_rate, overall_avg_pnl)
      }
      if stats[:win_rate] < 40 && stats[:trade_count] >= 5
        @anti_edges << edge
      elsif significant
        @edges << edge
      end
    end

    # Sort edges by score descending
    @edges.sort_by! { |e| -e[:edge_score] }
    @anti_edges.sort_by! { |e| e[:win_rate] }

    # Summary stats
    @edges_found = @edges.count
    @top_win_rate = @edges.any? ? @edges.max_by { |e| e[:win_rate] } : nil
    @best_symbol_edge = @edges.select { |e| e[:category] == "Symbol" }.first
    @strongest_edge = @edges.first

    # Trading Playbook: top 3
    @playbook = @edges.first(3)

    # Heatmap data: symbol x time of day
    @heatmap_symbols = []
    @heatmap_hours = []
    @heatmap_data = {}
    if symbol_groups.any? && hour_groups.any?
      top_symbols = symbol_groups.sort_by { |_, t| -t.count }.first(8).map(&:first)
      all_hours = hour_groups.keys.sort
      @heatmap_symbols = top_symbols
      @heatmap_hours = all_hours
      top_symbols.each do |sym|
        @heatmap_data[sym] = {}
        all_hours.each do |hr|
          matching = @trades.select { |t|
            (t["symbol"] || "").upcase == sym &&
              parse_hour(t["entry_time"].to_s)&.then { |h| format_hour(h) } == hr
          }
          if matching.any?
            w = matching.count { |t| t["pnl"].to_f > 0 }
            @heatmap_data[sym][hr] = { win_rate: (w.to_f / matching.count * 100).round(0), count: matching.count }
          end
        end
      end
    end

    # Categories for grouped display
    @categories = @edges.group_by { |e| e[:category] }
  end

  private

  def compute_edge_stats(trades)
    count = trades.count
    wins = trades.count { |t| t["pnl"].to_f > 0 }
    total_pnl = trades.sum { |t| t["pnl"].to_f }
    win_rate = count > 0 ? (wins.to_f / count * 100).round(1) : 0
    avg_pnl = count > 0 ? (total_pnl / count).round(2) : 0
    { trade_count: count, win_rate: win_rate, avg_pnl: avg_pnl, total_pnl: total_pnl.round(2) }
  end

  def compute_edge_score(stats, overall_wr, overall_avg)
    # Composite score: win rate advantage + expectancy advantage + volume bonus
    wr_advantage = stats[:win_rate] - overall_wr
    avg_advantage = overall_avg != 0 ? ((stats[:avg_pnl] - overall_avg) / [overall_avg.abs, 1].max * 50) : 0
    volume_bonus = [Math.log2([stats[:trade_count], 1].max) * 3, 20].min

    raw = (wr_advantage * 2) + avg_advantage + volume_bonus
    [raw.round(1), 0].max
  end

  def parse_hour(time_str)
    return nil if time_str.nil? || time_str.empty?
    begin
      Time.parse(time_str).hour
    rescue
      nil
    end
  end

  def format_hour(hour)
    if hour == 0
      "12 AM"
    elsif hour < 12
      "#{hour} AM"
    elsif hour == 12
      "12 PM"
    else
      "#{hour - 12} PM"
    end
  end
end

class PerformanceHeatmapController < ApplicationController
  before_action :require_api_connection

  include ActionView::Helpers::NumberHelper

  def show
    trade_result = api_client.trades(per_page: 1000)
    all_trades = trade_result.is_a?(Hash) ? (trade_result["trades"] || []) : Array(trade_result)
    all_trades = all_trades.select { |t| t.is_a?(Hash) }
    @trades = all_trades.select { |t| t["status"]&.downcase == "closed" && t["pnl"].present? }

    return if @trades.empty?

    # Pre-compute shared data
    avg_position_size = compute_avg_position_size(@trades)

    build_symbol_day_heatmap
    build_hour_day_heatmap
    build_month_year_heatmap
    build_direction_duration_heatmap
    build_size_time_heatmap(avg_position_size)
    compute_best_worst
  end

  private

  # ── Cell stats helper ──
  def cell_stats(trades)
    count = trades.count
    return nil if count < 3
    wins = trades.count { |t| t["pnl"].to_f > 0 }
    total_pnl = trades.sum { |t| t["pnl"].to_f }
    {
      trade_count: count,
      win_rate: (wins.to_f / count * 100).round(1),
      avg_pnl: (total_pnl / count).round(2),
      total_pnl: total_pnl.round(2)
    }
  end

  # ── Symbol x Day of Week ──
  def build_symbol_day_heatmap
    @day_labels = %w[Mon Tue Wed Thu Fri]
    symbol_groups = @trades.group_by { |t| (t["symbol"] || "Unknown").upcase }
    top_symbols = symbol_groups.sort_by { |_, ts| -ts.count }.first(12).map(&:first)
    @symbol_day_symbols = top_symbols
    @symbol_day_data = {}

    top_symbols.each do |sym|
      @symbol_day_data[sym] = {}
      @day_labels.each_with_index do |day_label, idx|
        wday = idx + 1 # Monday=1 ... Friday=5
        matching = (symbol_groups[sym] || []).select { |t|
          trade_wday(t) == wday
        }
        @symbol_day_data[sym][day_label] = cell_stats(matching)
      end
    end
  end

  # ── Hour x Day of Week ──
  def build_hour_day_heatmap
    @hour_day_hours = (6..20).to_a # 6 AM to 8 PM
    @hour_day_data = {}

    @hour_day_hours.each do |hour|
      @hour_day_data[hour] = {}
      @day_labels.each_with_index do |day_label, idx|
        wday = idx + 1
        matching = @trades.select { |t|
          h = parse_hour(t["entry_time"].to_s)
          w = trade_wday(t)
          h == hour && w == wday
        }
        @hour_day_data[hour][day_label] = cell_stats(matching)
      end
    end
  end

  # ── Month x Year (GitHub-style calendar) ──
  def build_month_year_heatmap
    @month_year_data = {}
    @month_labels = %w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec]

    year_month_groups = @trades.group_by { |t|
      date_str = (t["exit_time"] || t["entry_time"]).to_s.slice(0, 10)
      begin
        d = Date.parse(date_str)
        [d.year, d.month]
      rescue
        nil
      end
    }.reject { |k, _| k.nil? }

    @years = year_month_groups.keys.map(&:first).uniq.sort
    @years.each do |year|
      @month_year_data[year] = {}
      (1..12).each do |month|
        trades = year_month_groups[[year, month]] || []
        if trades.count >= 1
          total_pnl = trades.sum { |t| t["pnl"].to_f }
          wins = trades.count { |t| t["pnl"].to_f > 0 }
          @month_year_data[year][month] = {
            trade_count: trades.count,
            win_rate: (wins.to_f / trades.count * 100).round(1),
            avg_pnl: (total_pnl / trades.count).round(2),
            total_pnl: total_pnl.round(2)
          }
        end
      end
    end

    # Compute max absolute P&L for scaling
    all_monthly_pnl = @month_year_data.values.flat_map { |months|
      months.values.filter_map { |v| v&.dig(:total_pnl) }
    }
    @monthly_max_pnl = all_monthly_pnl.map(&:abs).max || 1

    # Build weekly calendar data for GitHub-style heatmap
    build_weekly_calendar
  end

  def build_weekly_calendar
    @calendar_weeks = []
    return if @trades.empty?

    # Get date range
    dates = @trades.filter_map { |t|
      date_str = (t["exit_time"] || t["entry_time"]).to_s.slice(0, 10)
      begin
        Date.parse(date_str)
      rescue
        nil
      end
    }
    return if dates.empty?

    min_date = dates.min.beginning_of_week(:sunday)
    max_date = dates.max.end_of_week(:sunday)

    # Group trades by date
    daily_pnl = {}
    @trades.each do |t|
      date_str = (t["exit_time"] || t["entry_time"]).to_s.slice(0, 10)
      begin
        d = Date.parse(date_str)
        daily_pnl[d] ||= 0.0
        daily_pnl[d] += t["pnl"].to_f
      rescue
        next
      end
    end

    @calendar_max_pnl = daily_pnl.values.map(&:abs).max || 1

    # Build weeks (columns in GitHub-style: each column is a week)
    current = min_date
    while current <= max_date
      week = []
      7.times do |dow|
        day = current + dow
        pnl = daily_pnl[day]
        week << { date: day, pnl: pnl }
      end
      @calendar_weeks << week
      current += 7
    end

    # Limit to last 52 weeks
    @calendar_weeks = @calendar_weeks.last(52) if @calendar_weeks.count > 52
  end

  # ── Direction x Duration ──
  def build_direction_duration_heatmap
    @directions = %w[Long Short]
    @durations = ["Scalp (<30m)", "Day Trade", "Swing (1-5d)", "Position (5d+)"]
    @dir_dur_data = {}

    @directions.each do |dir|
      @dir_dur_data[dir] = {}
      @durations.each do |dur|
        matching = @trades.select { |t|
          trade_direction(t) == dir && trade_duration_bucket(t) == dur
        }
        @dir_dur_data[dir][dur] = cell_stats(matching)
      end
    end
  end

  # ── Size x Time ──
  def build_size_time_heatmap(avg_position_size)
    @size_buckets = %w[Small Medium Large]
    @time_buckets = ["Pre-Market", "Morning", "Midday", "Afternoon", "After-Hours"]
    @size_time_data = {}

    @size_buckets.each do |size_label|
      @size_time_data[size_label] = {}
      @time_buckets.each do |time_label|
        matching = @trades.select { |t|
          position_size_bucket(t, avg_position_size) == size_label &&
            time_of_day_bucket(t) == time_label
        }
        @size_time_data[size_label][time_label] = cell_stats(matching)
      end
    end
  end

  # ── Best / Worst combinations ──
  def compute_best_worst
    @all_cells = []

    collect_cells("Symbol x Day", @symbol_day_symbols, @day_labels, @symbol_day_data)
    collect_cells_keyed("Hour x Day", @hour_day_hours, @day_labels, @hour_day_data) { |h| format_hour(h) }
    collect_cells("Direction x Duration", @directions, @durations, @dir_dur_data)
    collect_cells("Size x Time", @size_buckets, @time_buckets, @size_time_data)

    @cells_analyzed = @all_cells.count
    @data_points = @all_cells.sum { |c| c[:stats][:trade_count] }

    valid = @all_cells.select { |c| c[:stats][:trade_count] >= 3 }
    @best_combination = valid.max_by { |c| c[:stats][:win_rate] }
    @worst_combination = valid.min_by { |c| c[:stats][:win_rate] }
  end

  def collect_cells(heatmap_name, rows, cols, data)
    rows.each do |row|
      cols.each do |col|
        stats = data.dig(row, col)
        next unless stats
        @all_cells << { heatmap: heatmap_name, row: row.to_s, col: col, stats: stats }
      end
    end
  end

  def collect_cells_keyed(heatmap_name, rows, cols, data)
    rows.each do |row|
      label = block_given? ? yield(row) : row.to_s
      cols.each do |col|
        stats = data.dig(row, col)
        next unless stats
        @all_cells << { heatmap: heatmap_name, row: label, col: col, stats: stats }
      end
    end
  end

  # ── Parse helpers ──

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

  def trade_wday(trade)
    date_str = (trade["entry_time"] || trade["exit_time"]).to_s.slice(0, 10)
    begin
      Date.parse(date_str).wday
    rescue
      nil
    end
  end

  def trade_direction(trade)
    side = (trade["side"] || trade["direction"] || "").downcase
    if side.include?("long") || side.include?("buy")
      "Long"
    elsif side.include?("short") || side.include?("sell")
      "Short"
    else
      nil
    end
  end

  def trade_duration_bucket(trade)
    entry_str = trade["entry_time"].to_s
    exit_str = trade["exit_time"].to_s
    return nil if entry_str.empty? || exit_str.empty?
    begin
      entry_t = Time.parse(entry_str)
      exit_t = Time.parse(exit_str)
      minutes = ((exit_t - entry_t) / 60.0).abs
      if minutes < 30
        "Scalp (<30m)"
      elsif minutes < 1440
        "Day Trade"
      elsif minutes < 7200
        "Swing (1-5d)"
      else
        "Position (5d+)"
      end
    rescue
      nil
    end
  end

  def position_size_bucket(trade, avg_size)
    return nil if avg_size <= 0
    entry = trade["entry_price"].to_f
    qty = trade["quantity"].to_f
    return nil unless entry > 0 && qty > 0
    size = entry * qty
    ratio = size / avg_size
    if ratio < 0.5
      "Small"
    elsif ratio < 1.5
      "Medium"
    else
      "Large"
    end
  end

  def time_of_day_bucket(trade)
    hour = parse_hour(trade["entry_time"].to_s)
    return nil unless hour
    if hour < 9
      "Pre-Market"
    elsif hour < 11
      "Morning"
    elsif hour < 13
      "Midday"
    elsif hour < 16
      "Afternoon"
    else
      "After-Hours"
    end
  end

  def compute_avg_position_size(trades)
    sizes = trades.filter_map { |t|
      entry = t["entry_price"].to_f
      qty = t["quantity"].to_f
      entry > 0 && qty > 0 ? entry * qty : nil
    }
    sizes.any? ? sizes.sum / sizes.count : 0
  end
end

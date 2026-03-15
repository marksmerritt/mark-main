class TradeFeedController < ApplicationController
  def show
    @filter = params[:filter].presence || "all"
    today = Date.current

    trades = []
    journal_entries = []

    if api_token.present?
      threads = {}
      threads[:trades] = Thread.new {
        result = api_client.trades(per_page: 500)
        result.is_a?(Hash) ? (result["trades"] || []) : Array(result)
      }
      threads[:journal] = Thread.new {
        result = api_client.journal_entries(per_page: 100)
        result.is_a?(Hash) ? (result["journal_entries"] || []) : Array(result)
      }

      begin
        trades = threads[:trades].value || []
      rescue
        trades = []
      end

      begin
        journal_entries = threads[:journal].value || []
      rescue
        journal_entries = []
      end
    end

    # Build unified activity feed
    @events = []

    # --- Trade events ---
    closed_trades = trades.select { |t| t["status"] == "closed" || t["exit_time"].present? }
    open_trades = trades.select { |t| t["status"] != "closed" && t["exit_time"].blank? }

    # Track daily firsts and running P&L for milestones
    trades_by_day = {}
    cumulative_pnl = 0.0
    pnl_milestones_crossed = []

    sorted_trades = trades.sort_by { |t| (t["entry_time"] || t["created_at"]).to_s }

    sorted_trades.each do |t|
      entry_day = (t["entry_time"] || t["created_at"]).to_s.slice(0, 10)
      trades_by_day[entry_day] ||= []
      trades_by_day[entry_day] << t
    end

    # Trade opened events
    open_trades.each do |t|
      ts = t["entry_time"] || t["created_at"]
      side = t["side"]&.capitalize || "Trade"
      @events << {
        timestamp: ts.to_s,
        type: "trade_opened",
        icon: "login",
        color: "#1565c0",
        title: "Opened #{side} #{t['symbol']}",
        details: "#{t['quantity']} shares @ #{fmt_currency(t['entry_price'])}",
        pnl: nil,
        trade_id: t["id"],
        symbol: t["symbol"]
      }
    end

    # Trade closed events (including stop/target detection)
    closed_trades.each do |t|
      ts = t["exit_time"] || t["updated_at"] || t["created_at"]
      pnl_val = t["pnl"].to_f
      entry_price = t["entry_price"].to_f
      exit_price = t["exit_price"].to_f
      stop_loss = t["stop_loss"].to_f
      take_profit = t["take_profit"].to_f

      # Detect stop hit vs target hit
      event_type = "trade_closed"
      event_icon = pnl_val >= 0 ? "trending_up" : "trending_down"
      event_color = pnl_val >= 0 ? "var(--positive)" : "var(--negative)"
      event_title = "Closed #{t['symbol']}"

      if stop_loss > 0 && exit_price > 0
        tolerance = (stop_loss * 0.002).abs
        if (exit_price - stop_loss).abs <= tolerance
          event_type = "stop_hit"
          event_icon = "gpp_bad"
          event_color = "#d32f2f"
          event_title = "Stop Hit on #{t['symbol']}"
        end
      end

      if take_profit > 0 && exit_price > 0
        tolerance = (take_profit * 0.002).abs
        if (exit_price - take_profit).abs <= tolerance
          event_type = "target_hit"
          event_icon = "military_tech"
          event_color = "#2e7d32"
          event_title = "Target Hit on #{t['symbol']}"
        end
      end

      # Compute duration
      duration_str = ""
      if t["entry_time"].present? && t["exit_time"].present?
        begin
          entry_t = Time.parse(t["entry_time"])
          exit_t = Time.parse(t["exit_time"])
          dur_seconds = (exit_t - entry_t).to_i
          if dur_seconds < 60
            duration_str = "#{dur_seconds}s"
          elsif dur_seconds < 3600
            duration_str = "#{dur_seconds / 60}m"
          elsif dur_seconds < 86400
            hours = dur_seconds / 3600
            mins = (dur_seconds % 3600) / 60
            duration_str = "#{hours}h #{mins}m"
          else
            days = dur_seconds / 86400
            duration_str = "#{days}d"
          end
        rescue
          duration_str = ""
        end
      end

      details = "P&L: #{fmt_currency(pnl_val)}"
      details += " | Duration: #{duration_str}" if duration_str.present?

      @events << {
        timestamp: ts.to_s,
        type: event_type,
        icon: event_icon,
        color: event_color,
        title: event_title,
        details: details,
        pnl: pnl_val,
        trade_id: t["id"],
        symbol: t["symbol"]
      }
    end

    # --- Journal entry events ---
    journal_entries.each do |e|
      ts = e["date"] || e["created_at"]
      content = e["content"].to_s
      word_count = content.split.length
      title_text = e["title"].presence || "Journal Entry"
      mood = e["mood"]

      details_parts = []
      details_parts << "#{word_count} words" if word_count > 0
      details_parts << mood if mood.present?
      details_parts << content.truncate(80) if content.present?

      @events << {
        timestamp: ts.to_s,
        type: "journal",
        icon: "auto_stories",
        color: "#6a1b9a",
        title: title_text,
        details: details_parts.join(" | "),
        pnl: nil,
        journal_id: e["id"]
      }
    end

    # --- Milestone events ---
    # First trade of the day
    trades_by_day.each do |day, day_trades|
      first = day_trades.first
      next unless first
      ts = first["entry_time"] || first["created_at"]
      @events << {
        timestamp: ts.to_s,
        type: "milestone",
        icon: "wb_sunny",
        color: "#ef6c00",
        title: "First Trade of the Day",
        details: "#{first['side']&.capitalize} #{first['symbol']} to start #{format_day_label(day)}",
        pnl: nil
      }
    end

    # P&L milestones
    cumulative_pnl = 0.0
    crossed = {}
    [100, 500, 1000, 2000, 5000, 10000].each { |m| crossed[m] = false }

    sorted_closed = closed_trades.sort_by { |t| (t["exit_time"] || t["updated_at"] || t["created_at"]).to_s }
    sorted_closed.each do |t|
      pnl_val = t["pnl"].to_f
      prev_cumulative = cumulative_pnl
      cumulative_pnl += pnl_val
      ts = t["exit_time"] || t["updated_at"] || t["created_at"]

      crossed.each do |milestone, already_crossed|
        next if already_crossed
        if prev_cumulative < milestone && cumulative_pnl >= milestone
          crossed[milestone] = true
          @events << {
            timestamp: ts.to_s,
            type: "milestone",
            icon: "emoji_events",
            color: "#f9a825",
            title: "P&L Milestone: #{fmt_currency(milestone)}",
            details: "Cumulative profit reached #{fmt_currency(milestone)}!",
            pnl: cumulative_pnl
          }
        end
      end
    end

    # Streak milestones
    win_streak = 0
    max_streak = 0
    streak_milestones_fired = {}
    sorted_closed.each do |t|
      if t["pnl"].to_f > 0
        win_streak += 1
        max_streak = [max_streak, win_streak].max
        ts = t["exit_time"] || t["updated_at"] || t["created_at"]
        [3, 5, 10, 15, 20].each do |sm|
          if win_streak == sm && !streak_milestones_fired[sm]
            streak_milestones_fired[sm] = true
            @events << {
              timestamp: ts.to_s,
              type: "milestone",
              icon: "local_fire_department",
              color: "#e65100",
              title: "#{sm}-Win Streak!",
              details: "#{sm} consecutive winning trades in a row",
              pnl: nil
            }
          end
        end
      else
        win_streak = 0
      end
    end

    # --- Apply filter ---
    if @filter != "all"
      @events = @events.select do |e|
        case @filter
        when "trades"
          %w[trade_opened trade_closed stop_hit target_hit].include?(e[:type])
        when "journal"
          e[:type] == "journal"
        when "milestones"
          e[:type] == "milestone"
        else
          true
        end
      end
    end

    # Sort by timestamp descending
    @events.sort_by! { |e| e[:timestamp].to_s }.reverse!

    # Build running P&L alongside feed
    running = 0.0
    @running_pnl_data = []
    @events.reverse.each do |e|
      if e[:pnl]
        running += e[:pnl]
      end
      @running_pnl_data << running.round(2)
    end
    @running_pnl_data.reverse!
    @running_pnl = running.round(2)

    # Group by day
    @grouped = @events.group_by { |e| e[:timestamp].to_s.slice(0, 10) }

    # Today's summary
    today_str = today.to_s
    today_events = @events.select { |e| e[:timestamp].to_s.start_with?(today_str) }
    today_trades = today_events.select { |e| %w[trade_closed stop_hit target_hit].include?(e[:type]) }
    @trades_today = today_trades.count
    @pnl_today = today_trades.sum { |e| e[:pnl].to_f }
    wins_today = today_trades.count { |e| e[:pnl].to_f > 0 }
    @win_rate_today = @trades_today > 0 ? (wins_today.to_f / @trades_today * 100).round(1) : 0.0
    @journal_today = today_events.count { |e| e[:type] == "journal" }

    # Overall stats
    @total_events = @events.count
    @total_trade_events = @events.count { |e| %w[trade_opened trade_closed stop_hit target_hit].include?(e[:type]) }
    @total_journal_events = @events.count { |e| e[:type] == "journal" }
    @total_milestone_events = @events.count { |e| e[:type] == "milestone" }
  end

  private

  def fmt_currency(val)
    return "$0.00" if val.nil?
    v = val.to_f
    sign = v < 0 ? "-" : ""
    "#{sign}$#{'%.2f' % v.abs}"
  end

  def format_day_label(date_str)
    d = Date.parse(date_str) rescue nil
    return date_str unless d
    if d == Date.current
      "today"
    elsif d == Date.current - 1
      "yesterday"
    else
      d.strftime("%b %-d")
    end
  end
end

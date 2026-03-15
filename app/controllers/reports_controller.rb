class ReportsController < ApplicationController
  before_action :require_api_connection

  def index
  end

  def overview
    filter_params = params.permit(:start_date, :end_date).to_h.compact_blank
    @stats = api_client.overview(filter_params)
  end

  def by_symbol
    filter_params = params.permit(:start_date, :end_date).to_h.compact_blank
    @symbols = api_client.report_by_symbol(filter_params)
  end

  def by_tag
    filter_params = params.permit(:start_date, :end_date).to_h.compact_blank
    @tags = api_client.report_by_tag(filter_params)
  end

  def equity_curve
    filter_params = params.permit(:start_date, :end_date).to_h.compact_blank
    threads = {}
    threads[:curve] = Thread.new { api_client.equity_curve(filter_params) }
    threads[:trades] = Thread.new {
      api_client.trades(filter_params.merge(per_page: 500, status: "closed"))
    }

    @equity_data = threads[:curve].value
    result = threads[:trades].value
    trades = result.is_a?(Hash) ? (result["trades"] || []) : (result || [])

    # Build per-symbol equity curves (top 5 by volume)
    symbol_pnls = {}
    trades.sort_by { |t| t["entry_time"].to_s }.each do |trade|
      sym = trade["symbol"]
      date = trade["entry_time"]&.to_s&.slice(0, 10)
      next unless sym && date
      symbol_pnls[sym] ||= { dates: [], running: 0 }
      symbol_pnls[sym][:running] += trade["pnl"].to_f
      symbol_pnls[sym][:dates] << { date: date, cumulative: symbol_pnls[sym][:running].round(2) }
    end

    @symbol_curves = symbol_pnls
      .sort_by { |_, d| -d[:dates].count }
      .first(5)
      .to_h
  end

  def risk_analysis
    filter_params = params.permit(:start_date, :end_date).to_h.compact_blank
    @risk = api_client.risk_analysis(filter_params)
  end

  def by_time
    filter_params = params.permit(:start_date, :end_date).to_h.compact_blank

    threads = {}
    threads[:stats] = Thread.new { api_client.by_time(filter_params) }
    threads[:trades] = Thread.new {
      api_client.trades(filter_params.merge(per_page: 500, status: "closed"))
    }

    @time_stats = threads[:stats].value
    result = threads[:trades].value
    trades = result.is_a?(Hash) ? (result["trades"] || []) : (result || [])

    # Build hour x day heatmap grid
    @hour_day_grid = {}
    (0..23).each do |hour|
      @hour_day_grid[hour] = {}
      (0..6).each { |day| @hour_day_grid[hour][day] = { pnl: 0, count: 0, wins: 0 } }
    end

    trades.each do |trade|
      next unless trade["entry_time"].present?
      begin
        time = Time.parse(trade["entry_time"])
        hour = time.hour
        day = time.wday
        pnl = trade["pnl"].to_f
        @hour_day_grid[hour][day][:pnl] += pnl
        @hour_day_grid[hour][day][:count] += 1
        @hour_day_grid[hour][day][:wins] += 1 if pnl > 0
      rescue
        next
      end
    end

    # Session analysis
    @sessions = {
      premarket: { label: "Pre-Market", hours: (4..9), pnl: 0, count: 0, wins: 0 },
      open: { label: "Market Open", hours: (9..10), pnl: 0, count: 0, wins: 0 },
      midday: { label: "Mid-Day", hours: (11..13), pnl: 0, count: 0, wins: 0 },
      afternoon: { label: "Afternoon", hours: (14..15), pnl: 0, count: 0, wins: 0 },
      close: { label: "Market Close", hours: (15..16), pnl: 0, count: 0, wins: 0 }
    }

    trades.each do |trade|
      next unless trade["entry_time"].present?
      begin
        hour = Time.parse(trade["entry_time"]).hour
        pnl = trade["pnl"].to_f
        @sessions.each do |_, session|
          if session[:hours].include?(hour)
            session[:pnl] += pnl
            session[:count] += 1
            session[:wins] += 1 if pnl > 0
          end
        end
      rescue
        next
      end
    end
  end

  def by_duration
    filter_params = params.permit(:start_date, :end_date).to_h.compact_blank
    @duration_stats = api_client.by_duration(filter_params)
  end

  def heatmap
    @stats = api_client.overview
    @daily_pnl = @stats.is_a?(Hash) ? (@stats["daily_pnl"] || {}) : {}
  end

  def monte_carlo
    filter_params = params.permit(:start_date, :end_date).to_h.compact_blank
    threads = {}
    threads[:mc] = Thread.new { api_client.monte_carlo(filter_params) }
    threads[:trades] = Thread.new {
      api_client.trades(filter_params.merge(per_page: 500, status: "closed"))
    }
    @monte_carlo = threads[:mc].value
    result = threads[:trades].value
    trades = result.is_a?(Hash) ? (result["trades"] || []) : (result || [])

    # Build trade P&L array for additional analysis
    @trade_pnls = trades.map { |t| t["pnl"].to_f }
    @trade_count = trades.count
    if @trade_pnls.any?
      @avg_pnl = (@trade_pnls.sum / @trade_pnls.count).round(2)
      @pnl_stddev = Math.sqrt(@trade_pnls.map { |p| (p - @avg_pnl) ** 2 }.sum / @trade_pnls.count).round(2)
      @win_rate = (@trade_pnls.count { |p| p > 0 }.to_f / @trade_pnls.count * 100).round(1)
      @max_consecutive_loss = max_consecutive(trades, false)
      @max_consecutive_win = max_consecutive(trades, true)
    end
  end

  def distribution
    filter_params = params.permit(:start_date, :end_date).to_h.compact_blank
    @distribution = api_client.distribution(filter_params)
  end

  def setup_analysis
    filter_params = params.permit(:start_date, :end_date).to_h.compact_blank
    filter_params[:per_page] = 500
    filter_params[:status] = "closed"
    result = api_client.trades(filter_params)
    trades = result.is_a?(Hash) ? (result["trades"] || []) : (result || [])

    # Group by setup and analyze
    @setups = {}
    trades.each do |trade|
      setup = trade["setup"].presence || "No Setup"
      @setups[setup] ||= { trades: 0, wins: 0, losses: 0, total_pnl: 0, pnls: [] }
      @setups[setup][:trades] += 1
      pnl = trade["pnl"].to_f
      @setups[setup][:total_pnl] += pnl
      @setups[setup][:pnls] << pnl
      if pnl > 0
        @setups[setup][:wins] += 1
      elsif pnl < 0
        @setups[setup][:losses] += 1
      end
    end

    @setups.each do |_, data|
      data[:avg_pnl] = data[:trades] > 0 ? (data[:total_pnl] / data[:trades]).round(2) : 0
      data[:win_rate] = data[:trades] > 0 ? (data[:wins].to_f / data[:trades] * 100).round(1) : 0
      data[:best] = data[:pnls].max || 0
      data[:worst] = data[:pnls].min || 0
    end

    @setups = @setups.sort_by { |_, d| -d[:total_pnl] }.to_h
    @total_trades = trades.count
  end

  def streak_analysis
    filter_params = params.permit(:start_date, :end_date).to_h.compact_blank
    filter_params[:per_page] = 500
    filter_params[:status] = "closed"
    result = api_client.trades(filter_params)
    trades = result.is_a?(Hash) ? (result["trades"] || []) : (result || [])

    # Sort by date ascending
    trades.sort_by! { |t| t["entry_time"].to_s }

    # Build streak timeline
    @timeline = []
    current_streak = { type: nil, count: 0, pnl: 0, trades: [] }

    trades.each do |trade|
      pnl = trade["pnl"].to_f
      outcome = pnl > 0 ? "win" : (pnl < 0 ? "loss" : "breakeven")

      if outcome == "breakeven" || outcome == current_streak[:type]
        current_streak[:count] += 1
        current_streak[:pnl] += pnl
        current_streak[:trades] << trade
      else
        @timeline << current_streak.dup if current_streak[:type]
        current_streak = { type: outcome, count: 1, pnl: pnl, trades: [trade] }
      end
    end
    @timeline << current_streak.dup if current_streak[:type]

    # Summary stats
    win_streaks = @timeline.select { |s| s[:type] == "win" }
    loss_streaks = @timeline.select { |s| s[:type] == "loss" }

    @best_win_streak = win_streaks.max_by { |s| s[:count] }
    @worst_loss_streak = loss_streaks.max_by { |s| s[:count] }
    @avg_win_streak = win_streaks.any? ? (win_streaks.sum { |s| s[:count] }.to_f / win_streaks.count).round(1) : 0
    @avg_loss_streak = loss_streaks.any? ? (loss_streaks.sum { |s| s[:count] }.to_f / loss_streaks.count).round(1) : 0
    @total_trades = trades.count

    # After-streak analysis: what happens after a streak of N+
    @after_win_streak = analyze_after_streak(trades, "win", 3)
    @after_loss_streak = analyze_after_streak(trades, "loss", 3)

    # Consistency metrics
    pnls = trades.map { |t| t["pnl"].to_f }
    if pnls.length >= 5
      avg = pnls.sum / pnls.length
      stddev = Math.sqrt(pnls.map { |p| (p - avg) ** 2 }.sum / pnls.length)
      @consistency = {
        avg_pnl: avg.round(2),
        stddev: stddev.round(2),
        cv: avg != 0 ? (stddev / avg.abs * 100).round(0) : 0,
        positive_pct: (pnls.count { |p| p > 0 }.to_f / pnls.length * 100).round(1),
        profitable_days: 0,
        total_days: 0
      }

      # Daily aggregation for consistency
      daily = trades.group_by { |t| t["entry_time"].to_s.slice(0, 10) }
      daily_pnls = daily.map { |date, ts| { date: date, pnl: ts.sum { |t| t["pnl"].to_f } } }.sort_by { |d| d[:date] }
      @consistency[:total_days] = daily_pnls.count
      @consistency[:profitable_days] = daily_pnls.count { |d| d[:pnl] > 0 }
      @daily_pnls = daily_pnls

      # Running equity for consistency visualization
      @running_equity = []
      cumulative = 0.0
      pnls.each_with_index do |p, i|
        cumulative += p
        @running_equity << { trade: i + 1, equity: cumulative.round(2) }
      end
    end
  end

  def risk_reward
    filter_params = params.permit(:start_date, :end_date).to_h.compact_blank
    filter_params[:per_page] = 500
    filter_params[:status] = "closed"
    result = api_client.trades(filter_params)
    trades = result.is_a?(Hash) ? (result["trades"] || []) : (result || [])

    @trades_data = trades.filter_map do |trade|
      pnl = trade["pnl"].to_f
      entry = trade["entry_price"].to_f
      exit_price = trade["exit_price"].to_f
      qty = trade["quantity"].to_i

      next if entry.zero? || qty.zero?

      # Calculate risk as the adverse move (difference between entry and worst point)
      # Since we don't have intraday data, use the entry-exit spread as proxy
      risk = (entry - exit_price).abs * qty
      risk = [risk, 1].max # Avoid zero risk

      {
        symbol: trade["symbol"],
        side: trade["side"],
        pnl: pnl,
        risk: risk,
        rr_ratio: (pnl / risk).round(2),
        entry: entry,
        exit_price: exit_price,
        quantity: qty,
        date: trade["entry_time"]&.to_s&.slice(0, 10),
        id: trade["id"]
      }
    end

    # Summary stats
    if @trades_data.any?
      @avg_rr = (@trades_data.sum { |t| t[:rr_ratio] } / @trades_data.count).round(2)
      @best_rr = @trades_data.max_by { |t| t[:rr_ratio] }
      @worst_rr = @trades_data.min_by { |t| t[:rr_ratio] }

      winners = @trades_data.select { |t| t[:pnl] > 0 }
      losers = @trades_data.select { |t| t[:pnl] < 0 }
      @avg_win_rr = winners.any? ? (winners.sum { |t| t[:rr_ratio] } / winners.count).round(2) : 0
      @avg_loss_rr = losers.any? ? (losers.sum { |t| t[:rr_ratio] } / losers.count).round(2) : 0
    end
  end

  def correlation
    filter_params = params.permit(:start_date, :end_date).to_h.compact_blank
    filter_params[:per_page] = 500
    filter_params[:status] = "closed"
    result = api_client.trades(filter_params)
    trades = result.is_a?(Hash) ? (result["trades"] || []) : (result || [])

    # Group trades by date and symbol to build daily P&L matrix
    daily_by_symbol = {}
    trades.each do |trade|
      date = trade["entry_time"]&.to_s&.slice(0, 10)
      symbol = trade["symbol"]
      next unless date && symbol

      daily_by_symbol[symbol] ||= {}
      daily_by_symbol[symbol][date] = (daily_by_symbol[symbol][date] || 0) + trade["pnl"].to_f
    end

    # Only include symbols with enough trades
    @symbols = daily_by_symbol.select { |_, dates| dates.length >= 3 }.keys.sort
    all_dates = daily_by_symbol.values.flat_map(&:keys).uniq.sort

    # Compute correlation matrix
    @correlations = {}
    @symbols.each do |sym_a|
      @correlations[sym_a] = {}
      @symbols.each do |sym_b|
        if sym_a == sym_b
          @correlations[sym_a][sym_b] = 1.0
        else
          # Find common dates
          common_dates = all_dates.select { |d| daily_by_symbol[sym_a][d] && daily_by_symbol[sym_b][d] }
          if common_dates.length >= 3
            values_a = common_dates.map { |d| daily_by_symbol[sym_a][d] }
            values_b = common_dates.map { |d| daily_by_symbol[sym_b][d] }
            @correlations[sym_a][sym_b] = pearson_correlation(values_a, values_b)
          else
            @correlations[sym_a][sym_b] = nil
          end
        end
      end
    end

    # Symbol performance summary
    @symbol_stats = {}
    daily_by_symbol.each do |symbol, dates|
      pnls = dates.values
      @symbol_stats[symbol] = {
        trades: trades.count { |t| t["symbol"] == symbol },
        total_pnl: pnls.sum,
        avg_pnl: pnls.any? ? (pnls.sum / pnls.count).round(2) : 0,
        win_rate: pnls.any? ? (pnls.count { |p| p > 0 }.to_f / pnls.count * 100).round(1) : 0
      }
    end
    @symbol_stats = @symbol_stats.sort_by { |_, d| -d[:total_pnl] }.to_h
  end

  def execution_quality
    filter_params = params.permit(:start_date, :end_date).to_h.compact_blank
    filter_params[:per_page] = 500
    filter_params[:status] = "closed"
    result = api_client.trades(filter_params)
    trades = result.is_a?(Hash) ? (result["trades"] || []) : (result || [])

    @trades_analyzed = 0
    @metrics = {
      plan_adherence: { followed: 0, total: 0 },
      stop_discipline: { respected: 0, hit: 0, total_with_stops: 0 },
      target_capture: { hit: 0, total_with_targets: 0, capture_ratios: [] },
      risk_management: { within_plan: 0, over_risk: 0, total: 0 },
      mfe_capture: { ratios: [] },
      mae_control: { ratios: [] },
      grade_distribution: Hash.new(0),
      emotion_distribution: Hash.new(0)
    }

    trades.each do |trade|
      @trades_analyzed += 1
      entry = trade["entry_price"].to_f
      exit_p = trade["exit_price"].to_f
      pnl = trade["pnl"].to_f
      stop = trade["stop_loss"]&.to_f
      target = trade["take_profit"]&.to_f
      mfe = trade["max_favorable_excursion"]&.to_f
      mae = trade["max_adverse_excursion"]&.to_f
      is_long = trade["side"] == "long"

      # Plan adherence
      unless trade["followed_plan"].nil?
        @metrics[:plan_adherence][:total] += 1
        @metrics[:plan_adherence][:followed] += 1 if trade["followed_plan"]
      end

      # Stop discipline
      if stop && stop > 0
        @metrics[:stop_discipline][:total_with_stops] += 1
        if trade["stop_hit"]
          @metrics[:stop_discipline][:hit] += 1
          # Check if they actually exited at stop (respected it)
          exit_diff = is_long ? (exit_p - stop).abs : (stop - exit_p).abs
          @metrics[:stop_discipline][:respected] += 1 if exit_diff / entry < 0.02
        end
      end

      # Target capture
      if target && target > 0
        @metrics[:target_capture][:total_with_targets] += 1
        if trade["target_hit"]
          @metrics[:target_capture][:hit] += 1
        end
        # How much of the planned move was captured
        planned_move = (target - entry).abs
        actual_move = (exit_p - entry).abs
        if planned_move > 0
          @metrics[:target_capture][:capture_ratios] << (actual_move / planned_move * 100).round(1)
        end
      end

      # MFE capture efficiency (how much of max favorable was captured)
      if mfe && mfe > 0 && pnl != 0
        actual = pnl.abs / (trade["quantity"] || 1).to_f
        capture_pct = (actual / mfe * 100).clamp(0, 200).round(1)
        @metrics[:mfe_capture][:ratios] << capture_pct if pnl > 0
      end

      # MAE control (how well losses were limited)
      if mae && mae > 0 && pnl < 0
        loss_per_share = pnl.abs / (trade["quantity"] || 1).to_f
        control_pct = mae > 0 ? (loss_per_share / mae * 100).round(1) : 0
        @metrics[:mae_control][:ratios] << control_pct
      end

      # Grade distribution
      @metrics[:grade_distribution][trade["trade_grade"]] += 1 if trade["trade_grade"].present?

      # Emotion distribution
      @metrics[:emotion_distribution][trade["emotional_state"]] += 1 if trade["emotional_state"].present?
    end

    # Compute summary scores
    @scores = {}
    pa = @metrics[:plan_adherence]
    @scores[:plan_adherence] = pa[:total] > 0 ? (pa[:followed].to_f / pa[:total] * 100).round(1) : nil

    sd = @metrics[:stop_discipline]
    @scores[:stop_discipline] = sd[:total_with_stops] > 0 ? ((sd[:hit].to_f / sd[:total_with_stops]) * 100).round(1) : nil

    tc = @metrics[:target_capture]
    @scores[:target_hit_rate] = tc[:total_with_targets] > 0 ? (tc[:hit].to_f / tc[:total_with_targets] * 100).round(1) : nil
    @scores[:avg_capture] = tc[:capture_ratios].any? ? (tc[:capture_ratios].sum / tc[:capture_ratios].count).round(1) : nil

    mfe_r = @metrics[:mfe_capture][:ratios]
    @scores[:mfe_efficiency] = mfe_r.any? ? (mfe_r.sum / mfe_r.count).round(1) : nil

    mae_r = @metrics[:mae_control][:ratios]
    @scores[:mae_control] = mae_r.any? ? (mae_r.sum / mae_r.count).round(1) : nil

    # Overall execution score (weighted average of available metrics)
    components = []
    components << @scores[:plan_adherence] if @scores[:plan_adherence]
    components << @scores[:mfe_efficiency] if @scores[:mfe_efficiency]
    components << (100 - (@scores[:mae_control] || 100)) if @scores[:mae_control]
    components << @scores[:avg_capture] if @scores[:avg_capture]
    @overall_score = components.any? ? (components.sum / components.count).round(0) : nil
  end

  def period_comparison
    today = Date.current
    @period1_start = params[:period1_start].presence || today.beginning_of_month.to_s
    @period1_end   = params[:period1_end].presence   || today.to_s
    @period2_start = params[:period2_start].presence || (today - 1.month).beginning_of_month.to_s
    @period2_end   = params[:period2_end].presence   || (today - 1.month).end_of_month.to_s

    threads = {}
    threads[:trades1] = Thread.new {
      api_client.trades(start_date: @period1_start, end_date: @period1_end, per_page: 500, status: "closed")
    }
    threads[:trades2] = Thread.new {
      api_client.trades(start_date: @period2_start, end_date: @period2_end, per_page: 500, status: "closed")
    }

    result1 = threads[:trades1].value
    result2 = threads[:trades2].value
    trades1 = result1.is_a?(Hash) ? (result1["trades"] || []) : (result1 || [])
    trades2 = result2.is_a?(Hash) ? (result2["trades"] || []) : (result2 || [])

    @period1 = compute_period_stats(trades1)
    @period2 = compute_period_stats(trades2)
    @deltas  = compute_deltas(@period1, @period2)
  end

  def mood_analytics
    filter_params = params.permit(:start_date, :end_date).to_h.compact_blank

    threads = {}
    threads[:mood] = Thread.new { api_client.mood_analytics(filter_params) }
    threads[:trades] = Thread.new {
      api_client.trades(filter_params.merge(per_page: 500, status: "closed"))
    }
    threads[:journal] = Thread.new { api_client.journal_entries(filter_params) }

    @mood_data = threads[:mood].value
    @mood_data = {} unless @mood_data.is_a?(Hash)
    result = threads[:trades].value
    trades = result.is_a?(Hash) ? (result["trades"] || []) : (result || [])
    journal_result = threads[:journal].value
    journal_entries = if journal_result.is_a?(Hash)
      journal_result["journal_entries"] || []
    elsif journal_result.is_a?(Array)
      journal_result
    else
      []
    end

    # ---- Journal mood grouping ----
    @journal_by_mood = {}
    journal_entries.each do |entry|
      mood = entry["mood"].presence
      next unless mood
      @journal_by_mood[mood] ||= { count: 0, dates: [] }
      @journal_by_mood[mood][:count] += 1
      date = entry["date"]&.to_s&.slice(0, 10)
      @journal_by_mood[mood][:dates] << date if date
    end

    # Map journal dates to trades for mood-P&L correlation
    trades_by_date = {}
    trades.each do |trade|
      date = trade["entry_time"]&.to_s&.slice(0, 10)
      next unless date
      trades_by_date[date] ||= []
      trades_by_date[date] << trade
    end

    # Enrich with journal-mood -> daily P&L correlation
    @journal_mood_pnl = {}
    @journal_by_mood.each do |mood, data|
      @journal_mood_pnl[mood] = { journal_days: data[:count], trade_days: 0, total_pnl: 0, pnls: [], wins: 0, trades: 0 }
      data[:dates].each do |date|
        day_trades = trades_by_date[date]
        next unless day_trades&.any?
        @journal_mood_pnl[mood][:trade_days] += 1
        day_trades.each do |t|
          pnl = t["pnl"].to_f
          @journal_mood_pnl[mood][:total_pnl] += pnl
          @journal_mood_pnl[mood][:pnls] << pnl
          @journal_mood_pnl[mood][:trades] += 1
          @journal_mood_pnl[mood][:wins] += 1 if pnl > 0
        end
      end
      tc = @journal_mood_pnl[mood][:trades]
      @journal_mood_pnl[mood][:avg_pnl] = tc > 0 ? (@journal_mood_pnl[mood][:total_pnl] / tc).round(2) : 0
      @journal_mood_pnl[mood][:win_rate] = tc > 0 ? (@journal_mood_pnl[mood][:wins].to_f / tc * 100).round(1) : 0
    end

    # Build mood → performance breakdown
    @mood_performance = {}
    trades.each do |trade|
      mood = trade["emotional_state"].presence || "untagged"
      @mood_performance[mood] ||= { trades: 0, wins: 0, losses: 0, total_pnl: 0, pnls: [], sizes: [] }
      pnl = trade["pnl"].to_f
      @mood_performance[mood][:trades] += 1
      @mood_performance[mood][:total_pnl] += pnl
      @mood_performance[mood][:pnls] << pnl
      @mood_performance[mood][:sizes] << trade["quantity"].to_i
      @mood_performance[mood][:wins] += 1 if pnl > 0
      @mood_performance[mood][:losses] += 1 if pnl < 0
    end

    @mood_performance.each do |_, data|
      data[:avg_pnl] = data[:trades] > 0 ? (data[:total_pnl] / data[:trades]).round(2) : 0
      data[:win_rate] = data[:trades] > 0 ? (data[:wins].to_f / data[:trades] * 100).round(1) : 0
      data[:best] = data[:pnls].max || 0
      data[:worst] = data[:pnls].min || 0
      data[:avg_size] = data[:sizes].any? ? (data[:sizes].sum.to_f / data[:sizes].count).round(0) : 0
    end

    @mood_performance = @mood_performance.sort_by { |_, d| -d[:total_pnl] }.to_h

    # Best and worst mood (exclude untagged)
    tagged = @mood_performance.reject { |k, _| k == "untagged" }
    @best_mood = tagged.max_by { |_, d| d[:avg_pnl] }
    @worst_mood = tagged.min_by { |_, d| d[:avg_pnl] }
    @most_common_mood = tagged.max_by { |_, d| d[:trades] }

    # Mood frequency distribution
    @mood_distribution = tagged.transform_values { |d| d[:trades] }

    # Journal streak (consecutive days with journal entries)
    journal_dates = journal_entries.filter_map { |e| e["date"]&.to_s&.slice(0, 10) }.uniq.sort
    @journal_streak = 0
    if journal_dates.any?
      current_streak = 1
      max_streak = 1
      journal_dates.each_cons(2) do |a, b|
        begin
          if (Date.parse(b) - Date.parse(a)).to_i == 1
            current_streak += 1
            max_streak = current_streak if current_streak > max_streak
          else
            current_streak = 1
          end
        rescue
          current_streak = 1
        end
      end
      @journal_streak = max_streak
    end

    # Build mood timeline (mood per day with P&L)
    @mood_timeline = {}
    trades.sort_by { |t| t["entry_time"].to_s }.each do |trade|
      date = trade["entry_time"]&.to_s&.slice(0, 10)
      mood = trade["emotional_state"].presence
      next unless date && mood
      @mood_timeline[date] ||= { moods: Hash.new(0), pnl: 0 }
      @mood_timeline[date][:moods][mood] += 1
      @mood_timeline[date][:pnl] += trade["pnl"].to_f
    end

    # Monthly mood score trend
    mood_scores = {
      "confident" => 5, "disciplined" => 4, "calm" => 4, "focused" => 4, "excited" => 4,
      "neutral" => 3, "bored" => 2,
      "anxious" => 2, "fearful" => 1, "frustrated" => 1, "greedy" => 2, "fomo" => 1, "revenge" => 1
    }
    @monthly_mood_trend = {}
    trades.each do |trade|
      month = trade["entry_time"]&.to_s&.slice(0, 7)
      mood = trade["emotional_state"]&.downcase
      next unless month && mood && mood_scores[mood]
      @monthly_mood_trend[month] ||= { scores: [], pnl: 0, count: 0 }
      @monthly_mood_trend[month][:scores] << mood_scores[mood]
      @monthly_mood_trend[month][:pnl] += trade["pnl"].to_f
      @monthly_mood_trend[month][:count] += 1
    end
    journal_entries.each do |entry|
      month = entry["date"]&.to_s&.slice(0, 7)
      mood = entry["mood"]&.downcase
      next unless month && mood && mood_scores[mood]
      @monthly_mood_trend[month] ||= { scores: [], pnl: 0, count: 0 }
      @monthly_mood_trend[month][:scores] << mood_scores[mood]
    end
    @monthly_mood_trend = @monthly_mood_trend.sort_by { |k, _| k }.to_h
    @monthly_mood_trend.each do |_, data|
      data[:avg_score] = data[:scores].any? ? (data[:scores].sum.to_f / data[:scores].count).round(2) : 0
    end

    @mood_scores_map = mood_scores
    @total_trades = trades.count
    @tagged_count = trades.count { |t| t["emotional_state"].present? }
    @journal_count = journal_entries.count
    @journal_with_mood = journal_entries.count { |e| e["mood"].present? }
  end

  def monthly_performance
    @months = api_client.api_monthly_summary(months: params[:months] || 12)
    @months = [] unless @months.is_a?(Array)
  end

  def pnl_calendar
    @month_offset = params[:month].to_i
    @target_date = Date.current - @month_offset.months
    @month_start = @target_date.beginning_of_month
    @month_end = @target_date.end_of_month

    threads = {}
    threads[:overview] = Thread.new {
      api_client.overview(start_date: @month_start.to_s, end_date: (@month_end + 1.day).to_s)
    }
    threads[:trades] = Thread.new {
      api_client.trades(start_date: @month_start.to_s, end_date: (@month_end + 1.day).to_s, per_page: 200)
    }

    stats = threads[:overview].value
    @daily_pnl = stats.is_a?(Hash) ? (stats["daily_pnl"] || {}) : {}

    result = threads[:trades].value
    trades = result.is_a?(Hash) ? (result["trades"] || []) : (result || [])

    # Group trades by date
    @trades_by_date = {}
    trades.each do |trade|
      date = trade["entry_time"]&.to_s&.slice(0, 10)
      next unless date
      @trades_by_date[date] ||= []
      @trades_by_date[date] << trade
    end

    # Month stats
    pnl_values = @daily_pnl.values.map(&:to_f)
    @month_pnl = pnl_values.sum
    @trading_days = pnl_values.count
    @green_days = pnl_values.count { |p| p > 0 }
    @red_days = pnl_values.count { |p| p < 0 }
    @best_day = @daily_pnl.max_by { |_, v| v.to_f }
    @worst_day = @daily_pnl.min_by { |_, v| v.to_f }
    @avg_daily = @trading_days > 0 ? (@month_pnl / @trading_days).round(2) : 0
    @total_trades = trades.count
  end

  def fee_analysis
    filter_params = params.permit(:start_date, :end_date).to_h.compact_blank
    filter_params[:per_page] = 500
    filter_params[:status] = "closed"
    result = api_client.trades(filter_params)
    trades = result.is_a?(Hash) ? (result["trades"] || []) : (result || [])

    @total_trades = trades.count
    @total_commissions = trades.sum { |t| t["commissions"].to_f }
    @total_fees = trades.sum { |t| t["fees"].to_f }
    @total_costs = @total_commissions + @total_fees
    @gross_pnl = trades.sum { |t| t["pnl"].to_f } + @total_costs
    @net_pnl = trades.sum { |t| t["pnl"].to_f }
    @cost_per_trade = @total_trades > 0 ? (@total_costs / @total_trades).round(2) : 0
    @cost_as_pct = @gross_pnl.abs > 0 ? (@total_costs / @gross_pnl.abs * 100).round(2) : 0

    # Trades that were profitable before fees but not after
    @flipped_trades = trades.select { |t|
      pnl = t["pnl"].to_f
      costs = t["commissions"].to_f + t["fees"].to_f
      pnl < 0 && (pnl + costs) > 0
    }

    # Cost by symbol
    @cost_by_symbol = {}
    trades.each do |t|
      sym = t["symbol"] || "Unknown"
      @cost_by_symbol[sym] ||= { trades: 0, commissions: 0, fees: 0, pnl: 0, gross_pnl: 0 }
      @cost_by_symbol[sym][:trades] += 1
      @cost_by_symbol[sym][:commissions] += t["commissions"].to_f
      @cost_by_symbol[sym][:fees] += t["fees"].to_f
      @cost_by_symbol[sym][:pnl] += t["pnl"].to_f
      @cost_by_symbol[sym][:gross_pnl] += t["pnl"].to_f + t["commissions"].to_f + t["fees"].to_f
    end
    @cost_by_symbol.each do |_, d|
      d[:total_cost] = d[:commissions] + d[:fees]
      d[:cost_per_trade] = d[:trades] > 0 ? (d[:total_cost] / d[:trades]).round(2) : 0
      d[:fee_drag] = d[:gross_pnl].abs > 0 ? (d[:total_cost] / d[:gross_pnl].abs * 100).round(1) : 0
    end
    @cost_by_symbol = @cost_by_symbol.sort_by { |_, d| -d[:total_cost] }.to_h

    # Monthly cost trend
    @monthly_costs = {}
    trades.each do |t|
      month = t["entry_time"]&.to_s&.slice(0, 7)
      next unless month
      @monthly_costs[month] ||= { commissions: 0, fees: 0, trades: 0, pnl: 0 }
      @monthly_costs[month][:commissions] += t["commissions"].to_f
      @monthly_costs[month][:fees] += t["fees"].to_f
      @monthly_costs[month][:trades] += 1
      @monthly_costs[month][:pnl] += t["pnl"].to_f
    end
    @monthly_costs = @monthly_costs.sort_by { |k, _| k }.to_h

    # Cost by trade size (quantity buckets)
    @cost_by_size = {}
    trades.each do |t|
      qty = t["quantity"].to_i
      bucket = case qty
               when 0..10 then "1-10"
               when 11..50 then "11-50"
               when 51..100 then "51-100"
               when 101..500 then "101-500"
               else "500+"
               end
      @cost_by_size[bucket] ||= { trades: 0, total_cost: 0, avg_cost: 0 }
      @cost_by_size[bucket][:trades] += 1
      @cost_by_size[bucket][:total_cost] += t["commissions"].to_f + t["fees"].to_f
    end
    @cost_by_size.each { |_, d| d[:avg_cost] = d[:trades] > 0 ? (d[:total_cost] / d[:trades]).round(2) : 0 }

    # Win vs loss fee comparison
    winners = trades.select { |t| t["pnl"].to_f > 0 }
    losers = trades.select { |t| t["pnl"].to_f < 0 }
    @win_avg_cost = winners.any? ? (winners.sum { |t| t["commissions"].to_f + t["fees"].to_f } / winners.count).round(2) : 0
    @loss_avg_cost = losers.any? ? (losers.sum { |t| t["commissions"].to_f + t["fees"].to_f } / losers.count).round(2) : 0
  end

  def discipline
    filter_params = params.permit(:start_date, :end_date).to_h.compact_blank
    filter_params[:per_page] = 500
    filter_params[:status] = "closed"
    result = api_client.trades(filter_params)
    trades = result.is_a?(Hash) ? (result["trades"] || []) : (result || [])

    @total_trades = trades.count
    @graded_trades = trades.count { |t| t["trade_grade"].present? }
    @reviewed_trades = trades.count { |t| t["reviewed"] }
    @with_setup = trades.count { |t| t["setup"].present? }
    @with_notes = trades.count { |t| t["notes"].present? }
    @with_stops = trades.count { |t| t["stop_loss"].present? }
    @with_targets = trades.count { |t| t["take_profit"].present? }
    @with_plan = trades.count { |t| !t["followed_plan"].nil? }
    @followed_plan = trades.count { |t| t["followed_plan"] == true }
    @with_emotion = trades.count { |t| t["emotional_state"].present? }

    # Weekly discipline trends (last 8 weeks)
    @weekly_trends = []
    trades_by_week = trades.group_by { |t|
      date = Date.parse(t["entry_time"].to_s.slice(0, 10)) rescue nil
      date&.beginning_of_week(:monday)&.to_s
    }.reject { |k, _| k.nil? }

    trades_by_week.sort_by { |k, _| k }.last(8).each do |week, week_trades|
      total = week_trades.count
      next if total == 0
      @weekly_trends << {
        week: week,
        total: total,
        graded_pct: (week_trades.count { |t| t["trade_grade"].present? }.to_f / total * 100).round(0),
        setup_pct: (week_trades.count { |t| t["setup"].present? }.to_f / total * 100).round(0),
        stop_pct: (week_trades.count { |t| t["stop_loss"].present? }.to_f / total * 100).round(0),
        plan_pct: (week_trades.count { |t| t["followed_plan"] == true }.to_f / [week_trades.count { |t| !t["followed_plan"].nil? }, 1].max * 100).round(0),
        notes_pct: (week_trades.count { |t| t["notes"].present? }.to_f / total * 100).round(0)
      }
    end

    # Discipline score composite
    if @total_trades >= 5
      scores = []
      scores << (@graded_trades.to_f / @total_trades * 100) if @total_trades > 0
      scores << (@with_setup.to_f / @total_trades * 100) if @total_trades > 0
      scores << (@with_stops.to_f / @total_trades * 100) if @total_trades > 0
      scores << (@with_notes.to_f / @total_trades * 100) if @total_trades > 0
      scores << (@followed_plan.to_f / [@with_plan, 1].max * 100) if @with_plan > 0
      @discipline_score = scores.any? ? (scores.sum / scores.count).round(0) : 0
    end

    # Grade performance breakdown
    @grade_performance = {}
    trades.select { |t| t["trade_grade"].present? }.group_by { |t| t["trade_grade"] }.each do |grade, grade_trades|
      pnls = grade_trades.map { |t| t["pnl"].to_f }
      @grade_performance[grade] = {
        count: grade_trades.count,
        total_pnl: pnls.sum.round(2),
        avg_pnl: (pnls.sum / pnls.count).round(2),
        win_rate: (pnls.count { |p| p > 0 }.to_f / pnls.count * 100).round(1)
      }
    end

    # Emotional discipline: performance by emotional state
    @emotion_performance = {}
    calm_states = %w[calm focused confident disciplined]
    elevated_states = %w[anxious fearful greedy fomo revenge bored frustrated]
    trades.select { |t| t["emotional_state"].present? }.group_by { |t| t["emotional_state"] }.each do |state, state_trades|
      pnls = state_trades.map { |t| t["pnl"].to_f }
      @emotion_performance[state] = {
        count: state_trades.count,
        total_pnl: pnls.sum.round(2),
        avg_pnl: (pnls.sum / pnls.count).round(2),
        win_rate: (pnls.count { |p| p > 0 }.to_f / pnls.count * 100).round(1),
        category: calm_states.include?(state) ? :calm : :elevated
      }
    end
  end

  def risk_of_ruin
    filter_params = params.permit(:start_date, :end_date).to_h.compact_blank
    filter_params[:per_page] = 500
    filter_params[:status] = "closed"
    result = api_client.trades(filter_params)
    trades = result.is_a?(Hash) ? (result["trades"] || []) : (result || [])

    @total_trades = trades.count
    pnls = trades.map { |t| t["pnl"].to_f }

    if pnls.count >= 10
      @win_rate = (pnls.count { |p| p > 0 }.to_f / pnls.count * 100).round(1)
      @loss_rate = 100 - @win_rate

      winners = pnls.select { |p| p > 0 }
      losers = pnls.select { |p| p < 0 }
      @avg_win = winners.any? ? (winners.sum / winners.count).round(2) : 0
      @avg_loss = losers.any? ? (losers.sum / losers.count).abs.round(2) : 0

      @payoff_ratio = @avg_loss > 0 ? (@avg_win / @avg_loss).round(2) : 0

      # Edge per trade
      @edge = ((@win_rate / 100 * @avg_win) - (@loss_rate / 100 * @avg_loss)).round(2)

      # Kelly criterion
      if @avg_loss > 0 && @payoff_ratio > 0
        @kelly = ((@win_rate / 100 - (@loss_rate / 100 / @payoff_ratio)) * 100).round(1)
        @half_kelly = (@kelly / 2).round(1)
      else
        @kelly = 0
        @half_kelly = 0
      end

      # Account parameters
      @account_size = params[:account_size].present? ? params[:account_size].to_f : 25_000
      @risk_per_trade = params[:risk_per_trade].present? ? params[:risk_per_trade].to_f : 1.0
      @ruin_threshold = params[:ruin_threshold].present? ? params[:ruin_threshold].to_f : 50.0

      risk_amount = @account_size * @risk_per_trade / 100
      units_to_ruin = (@account_size * @ruin_threshold / 100) / risk_amount

      # Risk of ruin formula (simplified)
      # RoR = ((1 - edge) / (1 + edge))^units
      if @edge > 0 && @avg_loss > 0
        edge_ratio = @edge / risk_amount
        edge_ratio = edge_ratio.clamp(-0.99, 0.99)
        ruin_base = ((1 - edge_ratio) / (1 + edge_ratio)).abs
        @risk_of_ruin = (ruin_base ** units_to_ruin * 100).round(2)
        @risk_of_ruin = [@risk_of_ruin, 100].min
      else
        @risk_of_ruin = @edge <= 0 ? 100.0 : 0.0
      end

      # Monte Carlo simulation (1000 paths)
      @mc_paths = 5
      @mc_length = 200
      @mc_simulations = []
      srand(42) # Deterministic for consistent display
      rng = Random.new(42)
      surviving = 0
      total_sims = 1000
      ruin_count = 0
      max_dd_sum = 0

      total_sims.times do |sim|
        equity = @account_size
        peak = equity
        max_dd = 0
        path = sim < @mc_paths ? [equity] : nil

        @mc_length.times do
          if rng.rand(100.0) < @win_rate
            equity += @avg_win * (@risk_per_trade / 100 * @account_size / [@avg_loss, 1].max)
          else
            equity -= @avg_loss * (@risk_per_trade / 100 * @account_size / [@avg_loss, 1].max)
          end

          peak = equity if equity > peak
          dd = peak > 0 ? ((peak - equity) / peak * 100) : 0
          max_dd = dd if dd > max_dd

          path << equity.round(2) if path

          if equity <= @account_size * (1 - @ruin_threshold / 100)
            ruin_count += 1
            path << equity.round(2) if path
            break
          end
        end

        @mc_simulations << path if path
        surviving += 1 if equity > @account_size * (1 - @ruin_threshold / 100)
        max_dd_sum += max_dd
      end

      @mc_survival_rate = (surviving.to_f / total_sims * 100).round(1)
      @mc_ruin_rate = (ruin_count.to_f / total_sims * 100).round(1)
      @mc_avg_max_dd = (max_dd_sum / total_sims).round(1)

      # Maximum drawdown from actual trades
      cumulative = 0
      peak = 0
      @max_drawdown = 0
      @drawdown_history = []
      pnls.each do |p|
        cumulative += p
        peak = cumulative if cumulative > peak
        dd = peak > 0 ? ((peak - cumulative) / peak * 100) : 0
        @max_drawdown = dd if dd > @max_drawdown
        @drawdown_history << { equity: cumulative.round(2), drawdown: dd.round(1) }
      end
      @max_drawdown = @max_drawdown.round(1)

      # Consecutive loss analysis
      @max_consecutive_losses = 0
      current_streak = 0
      pnls.each do |p|
        if p < 0
          current_streak += 1
          @max_consecutive_losses = current_streak if current_streak > @max_consecutive_losses
        else
          current_streak = 0
        end
      end

      @consecutive_loss_impact = @max_consecutive_losses * @avg_loss
    end
  end

  def scorecard
    filter_params = params.permit(:start_date, :end_date).to_h.compact_blank
    threads = {}
    threads[:stats] = Thread.new { api_client.overview(filter_params) }
    threads[:risk] = Thread.new { api_client.risk_analysis(filter_params) }
    threads[:streaks] = Thread.new { api_client.streaks(filter_params) }

    @stats = threads[:stats].value
    @risk = threads[:risk].value
    @streaks = threads[:streaks].value
  end

  def expectancy
    filter_params = params.permit(:start_date, :end_date).to_h.compact_blank
    filter_params[:per_page] = 500
    filter_params[:status] = "closed"
    result = api_client.trades(filter_params)
    trades = result.is_a?(Hash) ? (result["trades"] || []) : (result || [])

    @total_trades = trades.count
    pnls = trades.map { |t| t["pnl"].to_f }

    if pnls.count >= 5
      winners = pnls.select { |p| p > 0 }
      losers = pnls.select { |p| p < 0 }

      @win_count = winners.count
      @loss_count = losers.count
      @win_rate = (@win_count.to_f / pnls.count * 100).round(1)
      @loss_rate = (100 - @win_rate).round(1)

      @avg_win = winners.any? ? (winners.sum / winners.count).round(2) : 0
      @avg_loss = losers.any? ? (losers.sum / losers.count).abs.round(2) : 0
      @median_win = winners.any? ? winners.sort[winners.length / 2].round(2) : 0
      @median_loss = losers.any? ? losers.sort[losers.length / 2].abs.round(2) : 0

      @payoff_ratio = @avg_loss > 0 ? (@avg_win / @avg_loss).round(2) : 0
      @expectancy = ((@win_rate / 100 * @avg_win) - (@loss_rate / 100 * @avg_loss)).round(2)
      @expectancy_per_dollar = @avg_loss > 0 ? (@expectancy / @avg_loss).round(2) : 0

      # Largest wins/losses
      @top_wins = trades.select { |t| t["pnl"].to_f > 0 }.sort_by { |t| -t["pnl"].to_f }.first(5)
      @top_losses = trades.select { |t| t["pnl"].to_f < 0 }.sort_by { |t| t["pnl"].to_f }.first(5)

      # P&L distribution buckets
      @distribution = {}
      bucket_size = @avg_loss > 0 ? (@avg_loss / 2).ceil : 50
      bucket_size = [bucket_size, 10].max
      pnls.each do |p|
        bucket = (p / bucket_size).floor * bucket_size
        key = "#{bucket >= 0 ? '+' : ''}#{bucket} to #{bucket >= 0 ? '+' : ''}#{bucket + bucket_size}"
        @distribution[key] ||= { count: 0, range_start: bucket }
        @distribution[key][:count] += 1
      end
      @distribution = @distribution.sort_by { |_, v| v[:range_start] }.to_h
      @max_bucket_count = @distribution.values.map { |v| v[:count] }.max.to_f
      @max_bucket_count = 1 if @max_bucket_count == 0

      # Running expectancy (rolling 20-trade window)
      @rolling_expectancy = []
      window = 20
      pnls.each_with_index do |_, i|
        next if i < window - 1
        window_pnls = pnls[i - window + 1..i]
        w = window_pnls.count { |p| p > 0 }
        l = window_pnls.count { |p| p < 0 }
        wr = w.to_f / window * 100
        aw = window_pnls.select { |p| p > 0 }.then { |ws| ws.any? ? ws.sum / ws.count : 0 }
        al = window_pnls.select { |p| p < 0 }.then { |ls| ls.any? ? (ls.sum / ls.count).abs : 0 }
        exp = (wr / 100 * aw) - ((100 - wr) / 100 * al)
        @rolling_expectancy << { trade: i + 1, expectancy: exp.round(2) }
      end

      # Edge by setup
      @setup_edge = {}
      trades.group_by { |t| t["setup"].presence || "No Setup" }.each do |setup, setup_trades|
        next if setup_trades.count < 3
        sp = setup_trades.map { |t| t["pnl"].to_f }
        sw = sp.count { |p| p > 0 }
        sl = sp.count { |p| p < 0 }
        swr = sw.to_f / sp.count * 100
        saw = sp.select { |p| p > 0 }.then { |ws| ws.any? ? ws.sum / ws.count : 0 }
        sal = sp.select { |p| p < 0 }.then { |ls| ls.any? ? (ls.sum / ls.count).abs : 0 }
        edge = (swr / 100 * saw) - ((100 - swr) / 100 * sal)
        @setup_edge[setup] = {
          trades: sp.count, win_rate: swr.round(1), avg_win: saw.round(2),
          avg_loss: sal.round(2), expectancy: edge.round(2), total_pnl: sp.sum.round(2)
        }
      end
      @setup_edge = @setup_edge.sort_by { |_, d| -d[:expectancy] }.to_h

      # Edge by side
      @side_edge = {}
      trades.group_by { |t| t["side"] || "unknown" }.each do |side, side_trades|
        sp = side_trades.map { |t| t["pnl"].to_f }
        sw = sp.count { |p| p > 0 }
        swr = sw.to_f / sp.count * 100
        saw = sp.select { |p| p > 0 }.then { |ws| ws.any? ? ws.sum / ws.count : 0 }
        sal = sp.select { |p| p < 0 }.then { |ls| ls.any? ? (ls.sum / ls.count).abs : 0 }
        edge = (swr / 100 * saw) - ((100 - swr) / 100 * sal)
        @side_edge[side] = {
          trades: sp.count, win_rate: swr.round(1), expectancy: edge.round(2), total_pnl: sp.sum.round(2)
        }
      end
    end
  end

  def position_sizing
    filter_params = params.permit(:start_date, :end_date).to_h.compact_blank
    filter_params[:per_page] = 500
    filter_params[:status] = "closed"
    result = api_client.trades(filter_params)
    trades = result.is_a?(Hash) ? (result["trades"] || []) : (result || [])

    @total_trades = trades.count
    trades.sort_by! { |t| t["entry_time"].to_s }

    pnls = trades.map { |t| t["pnl"].to_f }

    if pnls.count >= 10
      winners = pnls.select { |p| p > 0 }
      losers = pnls.select { |p| p < 0 }

      @win_rate = (winners.count.to_f / pnls.count * 100).round(1)
      @avg_win = winners.any? ? (winners.sum / winners.count).round(2) : 0
      @avg_loss = losers.any? ? (losers.sum / losers.count).abs.round(2) : 0
      @payoff_ratio = @avg_loss > 0 ? (@avg_win / @avg_loss).round(2) : 0
      @expectancy = ((@win_rate / 100 * @avg_win) - ((100 - @win_rate) / 100 * @avg_loss)).round(2)

      # Kelly criterion
      @kelly = @avg_loss > 0 && @payoff_ratio > 0 ?
        ((@win_rate / 100 - ((100 - @win_rate) / 100 / @payoff_ratio)) * 100).round(1) : 0
      @half_kelly = (@kelly / 2).round(1)

      # PnL volatility
      avg_pnl = pnls.sum / pnls.count
      @pnl_stddev = Math.sqrt(pnls.map { |p| (p - avg_pnl) ** 2 }.sum / pnls.count).round(2)

      # Account size for backtesting
      @account_size = params[:account_size].present? ? params[:account_size].to_f : 25_000

      # Backtest multiple strategies
      @strategies = {}

      # 1. Fixed 1% risk
      @strategies["fixed_1pct"] = backtest_strategy(trades, @account_size) { |equity, _trade, _i|
        equity * 0.01
      }
      @strategies["fixed_1pct"][:name] = "Fixed 1%"
      @strategies["fixed_1pct"][:description] = "Risk 1% of current equity per trade"

      # 2. Fixed 2% risk
      @strategies["fixed_2pct"] = backtest_strategy(trades, @account_size) { |equity, _trade, _i|
        equity * 0.02
      }
      @strategies["fixed_2pct"][:name] = "Fixed 2%"
      @strategies["fixed_2pct"][:description] = "Risk 2% of current equity per trade"

      # 3. Half Kelly
      kelly_frac = [@half_kelly / 100, 0.005].max
      kelly_frac = [kelly_frac, 0.10].min
      @strategies["half_kelly"] = backtest_strategy(trades, @account_size) { |equity, _trade, _i|
        equity * kelly_frac
      }
      @strategies["half_kelly"][:name] = "Half Kelly (#{(@half_kelly).round(1)}%)"
      @strategies["half_kelly"][:description] = "Kelly criterion / 2 for margin of safety"

      # 4. Anti-Martingale (increase after wins, decrease after losses)
      @strategies["anti_martingale"] = backtest_strategy(trades, @account_size) { |equity, _trade, i|
        if i == 0
          equity * 0.01
        else
          prev_pnl = trades[i - 1]["pnl"].to_f
          base = equity * 0.01
          prev_pnl > 0 ? base * 1.5 : base * 0.5
        end
      }
      @strategies["anti_martingale"][:name] = "Anti-Martingale"
      @strategies["anti_martingale"][:description] = "1.5x after wins, 0.5x after losses"

      # 5. Volatility-scaled (reduce size during volatile periods)
      rolling_window = 10
      @strategies["volatility_scaled"] = backtest_strategy(trades, @account_size) { |equity, _trade, i|
        if i < rolling_window
          equity * 0.01
        else
          recent = pnls[[i - rolling_window, 0].max...i]
          if recent.any?
            r_avg = recent.sum / recent.count
            r_vol = Math.sqrt(recent.map { |p| (p - r_avg) ** 2 }.sum / recent.count)
            target_vol = @pnl_stddev
            scale = target_vol > 0 && r_vol > 0 ? (target_vol / r_vol).clamp(0.3, 2.0) : 1.0
            equity * 0.01 * scale
          else
            equity * 0.01
          end
        end
      }
      @strategies["volatility_scaled"][:name] = "Vol-Scaled"
      @strategies["volatility_scaled"][:description] = "Adjusts size based on recent volatility"

      # 6. Fixed dollar
      @strategies["fixed_dollar"] = backtest_strategy(trades, @account_size) { |_equity, _trade, _i|
        @account_size * 0.01
      }
      @strategies["fixed_dollar"][:name] = "Fixed Dollar"
      @strategies["fixed_dollar"][:description] = "Risk same dollar amount every trade"

      # Rank strategies
      @ranked = @strategies.sort_by { |_, s| -s[:final_equity] }.to_h

      # Best strategy
      @best_key = @ranked.keys.first
      @best = @ranked[@best_key]

      # Actual equity curve (unmodified P&L)
      @actual_curve = []
      cum = @account_size
      pnls.each_with_index do |p, i|
        cum += p
        @actual_curve << { trade: i + 1, equity: cum.round(2) }
      end
      @actual_return = @account_size > 0 ? ((@actual_curve.last[:equity] - @account_size) / @account_size * 100).round(1) : 0
    end
  end

  def weekly_summary
    @week_offset = params[:week].to_i
    today = Date.current
    @week_start = (today - @week_offset.weeks).beginning_of_week(:monday)
    @week_end = @week_start.end_of_week(:monday)
    @prev_week_start = (@week_start - 1.week)
    @prev_week_end = @prev_week_start.end_of_week(:monday)

    threads = {}
    threads[:current] = Thread.new {
      api_client.overview(start_date: @week_start.to_s, end_date: @week_end.to_s)
    }
    threads[:previous] = Thread.new {
      api_client.overview(start_date: @prev_week_start.to_s, end_date: @prev_week_end.to_s)
    }
    threads[:trades] = Thread.new {
      api_client.trades(start_date: @week_start.to_s, end_date: @week_end.to_s, per_page: 100)
    }

    @current_week = threads[:current].value
    @previous_week = threads[:previous].value
    result = threads[:trades].value
    @week_trades = result.is_a?(Hash) ? (result["trades"] || []) : (result || [])
  end

  def leaderboard
    @months = (params[:months].presence || 3).to_i
    @min_trades = (params[:min_trades].presence || 1).to_i

    result = api_client.trades(status: "closed", per_page: 500)
    all_trades = result.is_a?(Hash) ? (result["trades"] || []) : (result || [])

    # Filter to time window
    cutoff = @months > 0 ? (Date.current - @months.months).to_s : nil
    trades = if cutoff
               all_trades.select { |t| t["entry_time"].to_s >= cutoff }
             else
               all_trades
             end

    trades.sort_by! { |t| t["entry_time"].to_s }

    # Helper: compute hold time in hours
    hold_time = ->(t) {
      entry = t["entry_time"].to_s
      exit_t = t["exit_time"].to_s
      if entry.present? && exit_t.present?
        begin
          ((Time.parse(exit_t) - Time.parse(entry)) / 3600.0).round(1)
        rescue
          nil
        end
      end
    }

    # ----- Top 10 Winners -----
    @top_winners = trades.select { |t| t["pnl"].to_f > 0 }
                         .sort_by { |t| -t["pnl"].to_f }
                         .first(10)
                         .each { |t| t["_hold_hours"] = hold_time.call(t) }

    # ----- Top 10 Losers -----
    @top_losers = trades.select { |t| t["pnl"].to_f < 0 }
                        .sort_by { |t| t["pnl"].to_f }
                        .first(10)
                        .each { |t| t["_hold_hours"] = hold_time.call(t) }

    # ----- Best Win Rate by Symbol -----
    symbol_groups = trades.group_by { |t| t["symbol"] }
    @symbol_stats = symbol_groups.filter_map { |sym, sym_trades|
      next if sym_trades.count < @min_trades
      wins = sym_trades.count { |t| t["pnl"].to_f > 0 }
      losses = sym_trades.count { |t| t["pnl"].to_f < 0 }
      total_pnl = sym_trades.sum { |t| t["pnl"].to_f }
      {
        symbol: sym,
        trades: sym_trades.count,
        wins: wins,
        losses: losses,
        win_rate: (wins.to_f / sym_trades.count * 100).round(1),
        total_pnl: total_pnl.round(2),
        avg_pnl: (total_pnl / sym_trades.count).round(2)
      }
    }.sort_by { |s| -s[:win_rate] }

    # ----- Most Traded Symbols -----
    @most_traded = symbol_groups.map { |sym, sym_trades|
      { symbol: sym, count: sym_trades.count, total_pnl: sym_trades.sum { |t| t["pnl"].to_f }.round(2) }
    }.sort_by { |s| -s[:count] }.first(10)

    # ----- Best R-Multiple Trades -----
    @best_r_multiples = trades.filter_map { |t|
      entry = t["entry_price"].to_f
      stop = t["stop_loss"]&.to_f
      exit_p = t["exit_price"].to_f
      pnl = t["pnl"].to_f
      next unless stop && stop > 0 && entry > 0 && (entry - stop).abs > 0
      risk_per_share = (entry - stop).abs
      r_multiple = pnl > 0 ? ((exit_p - entry).abs / risk_per_share).round(2) : -(((entry - exit_p).abs) / risk_per_share).round(2)
      {
        symbol: t["symbol"],
        entry: entry,
        stop: stop,
        exit_price: exit_p,
        r_multiple: r_multiple,
        pnl: pnl,
        date: t["entry_time"]&.to_s&.slice(0, 10),
        side: t["side"]
      }
    }.sort_by { |t| -t[:r_multiple] }.first(10)

    # ----- Longest Winning Streak -----
    @winning_streak = { count: 0, trades: [], pnl: 0 }
    current_streak = { count: 0, trades: [], pnl: 0 }
    trades.each do |t|
      if t["pnl"].to_f > 0
        current_streak[:count] += 1
        current_streak[:trades] << t
        current_streak[:pnl] += t["pnl"].to_f
        if current_streak[:count] > @winning_streak[:count]
          @winning_streak = current_streak.dup
          @winning_streak[:trades] = current_streak[:trades].dup
        end
      else
        current_streak = { count: 0, trades: [], pnl: 0 }
      end
    end

    # ----- Biggest Comeback -----
    # Trades where entry vs exit suggests the position moved against before closing positive
    @biggest_comebacks = trades.select { |t| t["pnl"].to_f > 0 }.filter_map { |t|
      entry = t["entry_price"].to_f
      exit_p = t["exit_price"].to_f
      is_long = t["side"] == "long"
      next unless entry > 0 && exit_p > 0

      # Use MAE if available, otherwise estimate adversity from price spread
      mae = t["max_adverse_excursion"]&.to_f
      adversity = if mae && mae > 0
                    mae
                  else
                    # For longs, if exit > entry that's a win, but spread hints at volatility
                    spread = (exit_p - entry).abs
                    qty = t["quantity"].to_i
                    qty > 0 ? spread * qty * 0.3 : 0 # rough estimate
                  end
      next if adversity <= 0

      {
        symbol: t["symbol"],
        pnl: t["pnl"].to_f,
        adversity: adversity.round(2),
        date: t["entry_time"]&.to_s&.slice(0, 10),
        side: t["side"],
        entry: entry,
        exit_price: exit_p
      }
    }.sort_by { |t| -t[:adversity] }.first(10)

    # ----- Fastest Wins -----
    @fastest_wins = trades.select { |t| t["pnl"].to_f > 0 }.filter_map { |t|
      hours = hold_time.call(t)
      next unless hours && hours > 0
      {
        symbol: t["symbol"],
        pnl: t["pnl"].to_f,
        hold_hours: hours,
        date: t["entry_time"]&.to_s&.slice(0, 10),
        side: t["side"]
      }
    }.sort_by { |t| t[:hold_hours] }.first(10)

    # ----- Hall of Fame -----
    # Single biggest win ever (across all trades, not filtered by time window)
    biggest_win_trade = all_trades.max_by { |t| t["pnl"].to_f }
    @hall_biggest_win = if biggest_win_trade && biggest_win_trade["pnl"].to_f > 0
                          {
                            symbol: biggest_win_trade["symbol"],
                            pnl: biggest_win_trade["pnl"].to_f,
                            date: biggest_win_trade["entry_time"]&.to_s&.slice(0, 10)
                          }
                        end

    # Best day ever (sum of same-day wins)
    daily_pnls = all_trades.group_by { |t| t["entry_time"]&.to_s&.slice(0, 10) }
                           .map { |date, day_trades|
                             { date: date, pnl: day_trades.sum { |t| t["pnl"].to_f }.round(2), count: day_trades.count }
                           }
                           .sort_by { |d| -d[:pnl] }
    @hall_best_day = daily_pnls.first

    # Best symbol ever (total P&L by symbol)
    all_symbol_pnls = all_trades.group_by { |t| t["symbol"] }
                                .map { |sym, sym_trades|
                                  { symbol: sym, pnl: sym_trades.sum { |t| t["pnl"].to_f }.round(2), trades: sym_trades.count }
                                }
                                .sort_by { |s| -s[:pnl] }
    @hall_best_symbol = all_symbol_pnls.first

    @total_trades = trades.count
  end

  def habits
    filter_params = params.permit(:start_date, :end_date).to_h.compact_blank
    filter_params[:per_page] = 500
    filter_params[:status] = "closed"
    result = api_client.trades(filter_params)
    trades = result.is_a?(Hash) ? (result["trades"] || []) : (result || [])
    trades.sort_by! { |t| t["entry_time"].to_s }

    @total_trades = trades.count
    return if @total_trades < 5

    pnls = trades.map { |t| t["pnl"].to_f }
    @total_pnl = pnls.sum.round(2)
    @win_rate = (trades.count { |t| t["pnl"].to_f > 0 }.to_f / @total_trades * 100).round(1)

    # --- Time of day analysis ---
    @by_hour = {}
    trades.each do |t|
      hour = Time.parse(t["entry_time"]).hour rescue nil
      next unless hour
      @by_hour[hour] ||= { trades: 0, wins: 0, pnl: 0 }
      @by_hour[hour][:trades] += 1
      @by_hour[hour][:wins] += 1 if t["pnl"].to_f > 0
      @by_hour[hour][:pnl] += t["pnl"].to_f
    end
    @by_hour.each do |h, d|
      d[:win_rate] = (d[:wins].to_f / d[:trades] * 100).round(1)
      d[:avg_pnl] = (d[:pnl] / d[:trades]).round(2)
      d[:pnl] = d[:pnl].round(2)
    end
    @best_hour = @by_hour.max_by { |_, d| d[:avg_pnl] }&.first
    @worst_hour = @by_hour.min_by { |_, d| d[:avg_pnl] }&.first

    # --- Day of week analysis ---
    @by_day = {}
    %w[Monday Tuesday Wednesday Thursday Friday Saturday Sunday].each_with_index do |name, i|
      @by_day[name] = { trades: 0, wins: 0, pnl: 0, index: i }
    end
    trades.each do |t|
      day_name = Date.parse(t["entry_time"].to_s.slice(0, 10)).strftime("%A") rescue nil
      next unless day_name && @by_day[day_name]
      @by_day[day_name][:trades] += 1
      @by_day[day_name][:wins] += 1 if t["pnl"].to_f > 0
      @by_day[day_name][:pnl] += t["pnl"].to_f
    end
    @by_day.each do |_, d|
      d[:win_rate] = d[:trades] > 0 ? (d[:wins].to_f / d[:trades] * 100).round(1) : 0
      d[:avg_pnl] = d[:trades] > 0 ? (d[:pnl] / d[:trades]).round(2) : 0
      d[:pnl] = d[:pnl].round(2)
    end
    @by_day = @by_day.select { |_, d| d[:trades] > 0 }
    @best_day = @by_day.max_by { |_, d| d[:avg_pnl] }&.first
    @worst_day = @by_day.min_by { |_, d| d[:avg_pnl] }&.first

    # --- Hold time analysis ---
    @hold_buckets = {
      "< 5 min" => { min: 0, max: 5, trades: 0, wins: 0, pnl: 0 },
      "5-15 min" => { min: 5, max: 15, trades: 0, wins: 0, pnl: 0 },
      "15-60 min" => { min: 15, max: 60, trades: 0, wins: 0, pnl: 0 },
      "1-4 hrs" => { min: 60, max: 240, trades: 0, wins: 0, pnl: 0 },
      "4 hrs - 1 day" => { min: 240, max: 1440, trades: 0, wins: 0, pnl: 0 },
      "1-5 days" => { min: 1440, max: 7200, trades: 0, wins: 0, pnl: 0 },
      "5+ days" => { min: 7200, max: Float::INFINITY, trades: 0, wins: 0, pnl: 0 }
    }
    trades.each do |t|
      entry = t["entry_time"].to_s
      exit_t = t["exit_time"].to_s
      next unless entry.present? && exit_t.present?
      minutes = ((Time.parse(exit_t) - Time.parse(entry)) / 60.0).round rescue nil
      next unless minutes && minutes >= 0
      @hold_buckets.each do |_, bucket|
        if minutes >= bucket[:min] && minutes < bucket[:max]
          bucket[:trades] += 1
          bucket[:wins] += 1 if t["pnl"].to_f > 0
          bucket[:pnl] += t["pnl"].to_f
          break
        end
      end
    end
    @hold_buckets.each do |_, d|
      d[:win_rate] = d[:trades] > 0 ? (d[:wins].to_f / d[:trades] * 100).round(1) : 0
      d[:avg_pnl] = d[:trades] > 0 ? (d[:pnl] / d[:trades]).round(2) : 0
      d[:pnl] = d[:pnl].round(2)
    end
    @hold_buckets = @hold_buckets.select { |_, d| d[:trades] > 0 }
    @best_duration = @hold_buckets.max_by { |_, d| d[:avg_pnl] }&.first

    # --- Position size analysis ---
    position_values = trades.filter_map { |t|
      entry = t["entry_price"].to_f
      qty = t["quantity"].to_i
      next unless entry > 0 && qty > 0
      { value: (entry * qty).round(2), pnl: t["pnl"].to_f }
    }
    if position_values.any?
      values = position_values.map { |p| p[:value] }
      @avg_position_size = (values.sum / values.count).round(2)
      @median_position_size = values.sort[values.count / 2].round(2)
      @max_position_size = values.max.round(2)
      @min_position_size = values.min.round(2)

      # Quartile analysis
      sorted = position_values.sort_by { |p| p[:value] }
      q1_idx = sorted.count / 4
      q3_idx = sorted.count * 3 / 4
      small = sorted[0...q1_idx]
      large = sorted[q3_idx..]
      @small_position_wr = small.any? ? (small.count { |p| p[:pnl] > 0 }.to_f / small.count * 100).round(1) : 0
      @large_position_wr = large.any? ? (large.count { |p| p[:pnl] > 0 }.to_f / large.count * 100).round(1) : 0
      @small_position_avg_pnl = small.any? ? (small.sum { |p| p[:pnl] } / small.count).round(2) : 0
      @large_position_avg_pnl = large.any? ? (large.sum { |p| p[:pnl] } / large.count).round(2) : 0
    end

    # --- Trade frequency patterns ---
    dates = trades.filter_map { |t| Date.parse(t["entry_time"]) rescue nil }
    @trades_by_date = dates.tally
    if @trades_by_date.any?
      @avg_trades_per_day = (@trades_by_date.values.sum.to_f / @trades_by_date.count).round(1)
      @max_trades_day = @trades_by_date.max_by { |_, c| c }
      @most_active_days = @trades_by_date.count

      # Volume clustering: do you trade more after wins or losses?
      @after_win_count = 0
      @after_loss_count = 0
      prev_day_pnl = nil
      @trades_by_date.sort.each do |date, count|
        day_trades = trades.select { |t| t["entry_time"].to_s.start_with?(date.to_s) }
        day_pnl = day_trades.sum { |t| t["pnl"].to_f }
        if prev_day_pnl
          if prev_day_pnl > 0
            @after_win_count += count
          elsif prev_day_pnl < 0
            @after_loss_count += count
          end
        end
        prev_day_pnl = day_pnl
      end
    end

    # --- First vs last trade of day ---
    @first_trade_stats = { count: 0, wins: 0, pnl: 0 }
    @last_trade_stats = { count: 0, wins: 0, pnl: 0 }
    trades.group_by { |t| t["entry_time"].to_s.slice(0, 10) }.each do |_, day_trades|
      sorted = day_trades.sort_by { |t| t["entry_time"].to_s }
      first = sorted.first
      last = sorted.last
      if first
        @first_trade_stats[:count] += 1
        @first_trade_stats[:wins] += 1 if first["pnl"].to_f > 0
        @first_trade_stats[:pnl] += first["pnl"].to_f
      end
      if last && sorted.count > 1
        @last_trade_stats[:count] += 1
        @last_trade_stats[:wins] += 1 if last["pnl"].to_f > 0
        @last_trade_stats[:pnl] += last["pnl"].to_f
      end
    end
    @first_trade_wr = @first_trade_stats[:count] > 0 ? (@first_trade_stats[:wins].to_f / @first_trade_stats[:count] * 100).round(1) : 0
    @last_trade_wr = @last_trade_stats[:count] > 0 ? (@last_trade_stats[:wins].to_f / @last_trade_stats[:count] * 100).round(1) : 0

    # --- Overtrading analysis ---
    @daily_trade_impact = {}
    trades.group_by { |t| t["entry_time"].to_s.slice(0, 10) }.each do |date, day_trades|
      count = day_trades.count
      bucket = case count
               when 1 then "1 trade"
               when 2..3 then "2-3 trades"
               when 4..6 then "4-6 trades"
               else "7+ trades"
               end
      @daily_trade_impact[bucket] ||= { days: 0, trades: 0, wins: 0, pnl: 0 }
      @daily_trade_impact[bucket][:days] += 1
      @daily_trade_impact[bucket][:trades] += count
      @daily_trade_impact[bucket][:wins] += day_trades.count { |t| t["pnl"].to_f > 0 }
      @daily_trade_impact[bucket][:pnl] += day_trades.sum { |t| t["pnl"].to_f }
    end
    @daily_trade_impact.each do |_, d|
      d[:win_rate] = d[:trades] > 0 ? (d[:wins].to_f / d[:trades] * 100).round(1) : 0
      d[:avg_daily_pnl] = d[:days] > 0 ? (d[:pnl] / d[:days]).round(2) : 0
      d[:pnl] = d[:pnl].round(2)
    end

    # --- Build habit insights ---
    @habits = []

    if @best_hour && @worst_hour && @by_hour[@best_hour][:avg_pnl] > 0 && @by_hour[@worst_hour][:avg_pnl] < 0
      @habits << {
        icon: "schedule",
        type: "positive",
        title: "Best Trading Hour",
        text: "You perform best at #{format_hour(@best_hour)} (avg +$#{@by_hour[@best_hour][:avg_pnl]}) and worst at #{format_hour(@worst_hour)} (avg $#{@by_hour[@worst_hour][:avg_pnl]}). Consider concentrating your activity during your best hours."
      }
    end

    if @best_day && @worst_day && @by_day[@best_day][:avg_pnl] > 0 && @by_day[@worst_day][:avg_pnl] < 0
      @habits << {
        icon: "calendar_month",
        type: "neutral",
        title: "Day-of-Week Edge",
        text: "#{@best_day}s are your strongest day (#{@by_day[@best_day][:win_rate]}% WR, avg +$#{@by_day[@best_day][:avg_pnl]}) while #{@worst_day}s are weakest (#{@by_day[@worst_day][:win_rate]}% WR, avg $#{@by_day[@worst_day][:avg_pnl]})."
      }
    end

    if @best_duration && @hold_buckets[@best_duration][:trades] >= 5
      @habits << {
        icon: "timer",
        type: "positive",
        title: "Optimal Hold Time",
        text: "Your best results come from #{@best_duration} holds (#{@hold_buckets[@best_duration][:win_rate]}% WR, avg +$#{@hold_buckets[@best_duration][:avg_pnl]}). Consider targeting this hold window."
      }
    end

    if @small_position_wr && @large_position_wr
      diff = @large_position_wr - @small_position_wr
      if diff.abs > 10
        better = diff > 0 ? "larger" : "smaller"
        @habits << {
          icon: "straighten",
          type: "neutral",
          title: "Position Size Impact",
          text: "You win more often with #{better} positions (#{diff > 0 ? @large_position_wr : @small_position_wr}% vs #{diff > 0 ? @small_position_wr : @large_position_wr}% WR). #{better == 'smaller' ? 'You may be overconfident on bigger bets.' : 'Your conviction trades tend to be right.'}"
        }
      end
    end

    if @first_trade_wr > 0 && @last_trade_wr > 0
      diff = @first_trade_wr - @last_trade_wr
      if diff > 10
        @habits << {
          icon: "wb_twilight",
          type: "warning",
          title: "Late-Day Deterioration",
          text: "Your first trade of day wins #{@first_trade_wr}% but your last trade drops to #{@last_trade_wr}%. Decision fatigue may be affecting your later trades."
        }
      end
    end

    if @after_win_count > 0 && @after_loss_count > 0
      ratio = @after_loss_count.to_f / @after_win_count
      if ratio > 1.3
        @habits << {
          icon: "psychology",
          type: "warning",
          title: "Revenge Trading Signal",
          text: "You take #{((ratio - 1) * 100).round(0)}% more trades after losing days (#{@after_loss_count} trades) vs winning days (#{@after_win_count} trades). This may indicate revenge trading behavior."
        }
      end
    end

    overtrade_bucket = @daily_trade_impact["7+ trades"]
    if overtrade_bucket && overtrade_bucket[:days] >= 3
      single_bucket = @daily_trade_impact["1 trade"]
      if single_bucket && single_bucket[:avg_daily_pnl] > overtrade_bucket[:avg_daily_pnl]
        @habits << {
          icon: "speed",
          type: "warning",
          title: "Overtrading Penalty",
          text: "Days with 7+ trades average $#{overtrade_bucket[:avg_daily_pnl]}/day vs $#{single_bucket[:avg_daily_pnl]}/day on 1-trade days. Less may be more."
        }
      end
    end
  end

  def equity_breakdown
    filter_params = params.permit(:start_date, :end_date).to_h.compact_blank
    filter_params[:per_page] = 500
    filter_params[:status] = "closed"
    result = api_client.trades(filter_params)
    trades = result.is_a?(Hash) ? (result["trades"] || []) : (result || [])
    trades.sort_by! { |t| t["entry_time"].to_s }

    @total_trades = trades.count
    return if @total_trades < 5

    @total_pnl = trades.sum { |t| t["pnl"].to_f }.round(2)

    # Overall equity curve
    @equity_curve = []
    running = 0
    trades.each_with_index do |t, i|
      running += t["pnl"].to_f
      @equity_curve << { trade: i + 1, equity: running.round(2), date: t["entry_time"].to_s.slice(0, 10) }
    end

    # By Side (Long vs Short)
    @by_side = {}
    trades.group_by { |t| t["side"] || "unknown" }.each do |side, side_trades|
      running = 0
      curve = side_trades.each_with_index.map { |t, i|
        running += t["pnl"].to_f
        { trade: i + 1, equity: running.round(2) }
      }
      wins = side_trades.count { |t| t["pnl"].to_f > 0 }
      @by_side[side] = {
        trades: side_trades.count,
        wins: wins,
        losses: side_trades.count - wins,
        win_rate: (wins.to_f / side_trades.count * 100).round(1),
        total_pnl: side_trades.sum { |t| t["pnl"].to_f }.round(2),
        avg_pnl: (side_trades.sum { |t| t["pnl"].to_f } / side_trades.count).round(2),
        curve: curve
      }
    end

    # By Asset Class
    @by_asset = {}
    trades.group_by { |t| t["asset_class"].presence || "Unknown" }.each do |asset, asset_trades|
      running = 0
      curve = asset_trades.each_with_index.map { |t, i|
        running += t["pnl"].to_f
        { trade: i + 1, equity: running.round(2) }
      }
      wins = asset_trades.count { |t| t["pnl"].to_f > 0 }
      @by_asset[asset] = {
        trades: asset_trades.count,
        wins: wins,
        win_rate: (wins.to_f / asset_trades.count * 100).round(1),
        total_pnl: asset_trades.sum { |t| t["pnl"].to_f }.round(2),
        curve: curve
      }
    end
    @by_asset = @by_asset.sort_by { |_, d| -d[:total_pnl] }.to_h

    # By Month
    @by_month = {}
    trades.group_by { |t| t["entry_time"].to_s.slice(0, 7) }.each do |month, month_trades|
      wins = month_trades.count { |t| t["pnl"].to_f > 0 }
      total = month_trades.sum { |t| t["pnl"].to_f }
      @by_month[month] = {
        trades: month_trades.count,
        wins: wins,
        losses: month_trades.count - wins,
        win_rate: (wins.to_f / month_trades.count * 100).round(1),
        total_pnl: total.round(2),
        avg_pnl: (total / month_trades.count).round(2)
      }
    end
    @by_month = @by_month.sort.to_h

    # Contribution analysis: what % of total P&L comes from each dimension
    @side_contribution = @by_side.map { |side, d|
      pct = @total_pnl != 0 ? (d[:total_pnl] / @total_pnl.abs * 100).round(1) : 0
      { name: side.capitalize, pnl: d[:total_pnl], pct: pct }
    }
    @asset_contribution = @by_asset.map { |asset, d|
      pct = @total_pnl != 0 ? (d[:total_pnl] / @total_pnl.abs * 100).round(1) : 0
      { name: asset.capitalize, pnl: d[:total_pnl], pct: pct }
    }
  end

  def playbook_performance
    threads = {}
    threads[:playbooks] = Thread.new { api_client.playbooks rescue [] }
    threads[:trades] = Thread.new {
      result = api_client.trades(status: "closed", per_page: 500)
      result.is_a?(Hash) ? (result["trades"] || []) : (result || [])
    }

    pb_result = threads[:playbooks].value
    @playbooks = pb_result.is_a?(Hash) ? (pb_result["playbooks"] || [pb_result]) : (pb_result || [])
    @playbooks = Array.wrap(@playbooks).reject { |p| p.is_a?(Hash) && p["error"] }
    trades = threads[:trades].value
    trades.sort_by! { |t| t["entry_time"].to_s }

    @total_trades = trades.count
    return if @total_trades < 5

    # Group trades by setup/playbook
    by_setup = trades.group_by { |t| t["setup"].presence || "No Playbook" }

    @setup_performance = by_setup.filter_map { |setup, setup_trades|
      next if setup_trades.count < 2
      pnls = setup_trades.map { |t| t["pnl"].to_f }
      wins = pnls.count { |p| p > 0 }
      losses = pnls.count { |p| p < 0 }
      total_pnl = pnls.sum
      win_rate = (wins.to_f / pnls.count * 100).round(1)
      avg_win = pnls.select { |p| p > 0 }.then { |w| w.any? ? w.sum / w.count : 0 }
      avg_loss = pnls.select { |p| p < 0 }.then { |l| l.any? ? (l.sum / l.count).abs : 0 }
      expectancy = (win_rate / 100 * avg_win) - ((100 - win_rate) / 100 * avg_loss)
      profit_factor = avg_loss > 0 ? (wins * avg_win / (losses * avg_loss)).round(2) : 0

      # Equity curve for this setup
      curve = []
      running = 0
      pnls.each_with_index do |p, i|
        running += p
        curve << { trade: i + 1, equity: running.round(2) }
      end

      # Max drawdown
      peak = 0
      max_dd = 0
      running = 0
      pnls.each do |p|
        running += p
        peak = running if running > peak
        dd = peak > 0 ? ((peak - running) / peak * 100) : 0
        max_dd = dd if dd > max_dd
      end

      # Linked playbook
      playbook = @playbooks.find { |pb| pb["name"].to_s.downcase == setup.downcase }

      # Grade
      grade = if expectancy > 50 && win_rate >= 55 then "A"
              elsif expectancy > 0 && win_rate >= 50 then "B"
              elsif expectancy > 0 then "C"
              elsif total_pnl >= 0 then "D"
              else "F"
              end

      {
        name: setup,
        trades: pnls.count,
        wins: wins,
        losses: losses,
        win_rate: win_rate,
        total_pnl: total_pnl.round(2),
        avg_pnl: (total_pnl / pnls.count).round(2),
        avg_win: avg_win.round(2),
        avg_loss: avg_loss.round(2),
        expectancy: expectancy.round(2),
        profit_factor: profit_factor,
        max_drawdown: max_dd.round(1),
        curve: curve,
        grade: grade,
        has_playbook: playbook.present?,
        playbook_id: playbook&.dig("id")
      }
    }.sort_by { |s| -s[:expectancy] }

    # Overall stats
    @with_playbook = trades.count { |t| t["setup"].present? }
    @without_playbook = trades.count { |t| t["setup"].blank? }
    @with_pb_pnl = trades.select { |t| t["setup"].present? }.sum { |t| t["pnl"].to_f }
    @without_pb_pnl = trades.select { |t| t["setup"].blank? }.sum { |t| t["pnl"].to_f }
    @with_pb_wr = @with_playbook > 0 ?
      (trades.select { |t| t["setup"].present? }.count { |t| t["pnl"].to_f > 0 }.to_f / @with_playbook * 100).round(1) : 0
    @without_pb_wr = @without_playbook > 0 ?
      (trades.select { |t| t["setup"].blank? }.count { |t| t["pnl"].to_f > 0 }.to_f / @without_playbook * 100).round(1) : 0

    @best_setup = @setup_performance.first
    @worst_setup = @setup_performance.last
  end

  def session_log
    @week_offset = params[:week].to_i
    @week_start = (Date.current - @week_offset.weeks).beginning_of_week(:monday)
    @week_end = @week_start.end_of_week(:monday)

    threads = {}
    threads[:trades] = Thread.new {
      result = api_client.trades(
        start_date: @week_start.to_s,
        end_date: (@week_end + 1.day).to_s,
        per_page: 200
      )
      result.is_a?(Hash) ? (result["trades"] || []) : (result || [])
    }
    threads[:journal] = Thread.new {
      result = api_client.journal_entries(
        start_date: @week_start.to_s,
        end_date: @week_end.to_s
      )
      entries = result.is_a?(Hash) ? (result["journal_entries"] || []) : (result || [])
      entries.index_by { |e| e["date"].to_s.slice(0, 10) }
    }

    trades = threads[:trades].value
    @journal_by_date = threads[:journal].value || {}

    # Group by date → sessions
    @sessions = {}
    trades.each do |t|
      date = t["entry_time"].to_s.slice(0, 10)
      next unless date.present?
      @sessions[date] ||= { trades: [], pnl: 0, wins: 0, losses: 0 }
      @sessions[date][:trades] << t
      pnl = t["pnl"].to_f
      @sessions[date][:pnl] += pnl
      @sessions[date][:wins] += 1 if pnl > 0
      @sessions[date][:losses] += 1 if pnl < 0
    end

    @sessions.each do |date, session|
      count = session[:trades].count
      session[:pnl] = session[:pnl].round(2)
      session[:win_rate] = count > 0 ? (session[:wins].to_f / count * 100).round(1) : 0
      session[:trade_count] = count

      # Session timeline
      sorted = session[:trades].sort_by { |t| t["entry_time"].to_s }
      session[:first_trade_time] = sorted.first["entry_time"]
      session[:last_trade_time] = sorted.last["exit_time"].presence || sorted.last["entry_time"]

      # Running P&L within session
      running = 0
      session[:running_pnl] = sorted.map { |t|
        running += t["pnl"].to_f
        { symbol: t["symbol"], pnl: t["pnl"].to_f, cumulative: running.round(2), time: t["entry_time"] }
      }

      # Grade the session
      session[:grade] = if session[:pnl] > 0 && session[:win_rate] >= 60
                          "A"
                        elsif session[:pnl] > 0
                          "B"
                        elsif session[:pnl] == 0
                          "C"
                        elsif session[:pnl] > -100
                          "D"
                        else
                          "F"
                        end

      # Journal entry for this date
      session[:journal] = @journal_by_date[date]
    end

    @sessions = @sessions.sort.reverse.to_h

    # Week summary
    @week_pnl = @sessions.values.sum { |s| s[:pnl] }
    @week_trades = @sessions.values.sum { |s| s[:trade_count] }
    @week_wins = @sessions.values.sum { |s| s[:wins] }
    @week_losses = @sessions.values.sum { |s| s[:losses] }
    @week_win_rate = @week_trades > 0 ? (@week_wins.to_f / @week_trades * 100).round(1) : 0
    @green_days = @sessions.values.count { |s| s[:pnl] > 0 }
    @red_days = @sessions.values.count { |s| s[:pnl] < 0 }
    @best_session = @sessions.max_by { |_, s| s[:pnl] }
    @worst_session = @sessions.min_by { |_, s| s[:pnl] }
  end

  def what_if
    filter_params = params.permit(:start_date, :end_date).to_h.compact_blank
    result = api_client.trades(filter_params.merge(per_page: 500, status: "closed"))
    trades = result.is_a?(Hash) ? (result["trades"] || []) : (result || [])
    trades = trades.sort_by { |t| t["entry_time"].to_s }

    # --- Baseline stats ---
    pnls = trades.map { |t| t["pnl"].to_f }
    wins = pnls.select { |p| p > 0 }
    losses = pnls.select { |p| p < 0 }

    @trade_count = trades.count
    @baseline = {
      total_pnl: pnls.sum.round(2),
      win_rate: pnls.any? ? (wins.count.to_f / pnls.count * 100).round(1) : 0,
      avg_win: wins.any? ? (wins.sum / wins.count).round(2) : 0,
      avg_loss: losses.any? ? (losses.sum / losses.count).round(2).abs : 0,
      profit_factor: losses.any? && losses.sum != 0 ? (wins.sum / losses.sum.abs).round(2) : 0,
      max_drawdown: what_if_max_drawdown(pnls),
      equity_curve: what_if_equity_curve(pnls)
    }

    avg_win = @baseline[:avg_win]
    one_r = avg_win > 0 ? avg_win : 1

    @scenarios = []

    # --- Scenario A: Cut losses at 1R ---
    capped_pnls = pnls.map { |p| p < 0 ? [p, -one_r].max : p }
    @scenarios << build_scenario(
      "Cut Losses at 1R",
      "What if every losing trade was capped at -$#{number_with_precision(one_r, precision: 0)} (1x your average win)?",
      capped_pnls,
      "content_cut",
      "#e91e63"
    )

    # --- Scenario B: Size up winners 1.5x ---
    sized_pnls = pnls.map { |p| p > 0 ? (p * 1.5).round(2) : p }
    @scenarios << build_scenario(
      "Size Up Winners 1.5x",
      "What if you added 50% more size to every winning trade?",
      sized_pnls,
      "trending_up",
      "#1a73e8"
    )

    # --- Scenario C: Skip worst 5 trades ---
    if pnls.count > 5
      sorted_indices = pnls.each_with_index.sort_by { |p, _| p }.first(5).map(&:last).to_set
      skip_pnls = pnls.each_with_index.reject { |_, i| sorted_indices.include?(i) }.map(&:first)
    else
      skip_pnls = pnls.dup
    end
    worst_5_total = pnls.sort.first(5).sum.round(2) rescue 0
    @scenarios << build_scenario(
      "Skip Worst 5 Trades",
      "What if you avoided your 5 biggest losers (#{number_to_currency(worst_5_total)} total)?",
      skip_pnls,
      "remove_circle_outline",
      "#f9ab00"
    )

    # --- Scenario D: Only trade best setup ---
    setups = {}
    trades.each do |t|
      setup = t["setup"].presence || "No Setup"
      setups[setup] ||= []
      setups[setup] << t["pnl"].to_f
    end
    # Best setup by expectancy (avg pnl) with min 5 trades
    best_setup_name, best_setup_pnls = setups
      .select { |_, ps| ps.count >= 5 }
      .max_by { |_, ps| ps.sum / ps.count } || [nil, nil]

    if best_setup_name && best_setup_pnls
      @scenarios << build_scenario(
        "Only Best Setup",
        "What if you only traded \"#{best_setup_name}\" (#{best_setup_pnls.count} trades, highest expectancy)?",
        best_setup_pnls,
        "star",
        "#0d904f"
      )
    else
      # Fallback if no setup has 5+ trades
      @scenarios << build_scenario(
        "Only Best Setup",
        "Not enough setup data (need at least one setup with 5+ trades).",
        pnls,
        "star",
        "#0d904f"
      )
    end

    # --- Scenario E: Only morning trades (before 11am) ---
    morning_pnls = trades.select { |t|
      begin
        Time.parse(t["entry_time"]).hour < 11
      rescue
        false
      end
    }.map { |t| t["pnl"].to_f }
    morning_pnls = pnls if morning_pnls.empty? # Fallback
    morning_count = trades.count { |t|
      begin
        Time.parse(t["entry_time"]).hour < 11
      rescue
        false
      end
    }
    @scenarios << build_scenario(
      "Morning Only (Before 11 AM)",
      "What if you only traded before 11:00 AM? (#{morning_count} of #{trades.count} trades)",
      morning_pnls,
      "wb_sunny",
      "#9c27b0"
    )

    # --- Best scenario ---
    @best_scenario = @scenarios.max_by { |s| s[:pnl_diff] }
  end

  private

  def build_scenario(name, description, pnls, icon, color)
    wins = pnls.select { |p| p > 0 }
    losses = pnls.select { |p| p < 0 }
    total_pnl = pnls.sum.round(2)
    {
      name: name,
      description: description,
      icon: icon,
      color: color,
      trade_count: pnls.count,
      total_pnl: total_pnl,
      pnl_diff: (total_pnl - @baseline[:total_pnl]).round(2),
      win_rate: pnls.any? ? (wins.count.to_f / pnls.count * 100).round(1) : 0,
      profit_factor: losses.any? && losses.sum != 0 ? (wins.sum / losses.sum.abs).round(2) : 0,
      max_drawdown: what_if_max_drawdown(pnls),
      equity_curve: what_if_equity_curve(pnls)
    }
  end

  def what_if_equity_curve(pnls)
    cumulative = 0
    pnls.each_with_index.map { |p, i| cumulative += p; { index: i, value: cumulative.round(2) } }
  end

  def what_if_max_drawdown(pnls)
    peak = 0
    cumulative = 0
    max_dd = 0
    pnls.each do |p|
      cumulative += p
      peak = cumulative if cumulative > peak
      dd = peak - cumulative
      max_dd = dd if dd > max_dd
    end
    max_dd.round(2)
  end

  def format_hour(h)
    if h == 0 then "12:00 AM"
    elsif h < 12 then "#{h}:00 AM"
    elsif h == 12 then "12:00 PM"
    else "#{h - 12}:00 PM"
    end
  end

  def analyze_after_streak(trades, streak_type, min_length)
    # Find trades that come right after a streak of min_length+
    results = []
    streak_count = 0
    streak_active = false

    trades.each_with_index do |trade, i|
      pnl = trade["pnl"].to_f
      outcome = pnl > 0 ? "win" : (pnl < 0 ? "loss" : "breakeven")

      if outcome == streak_type
        streak_count += 1
        streak_active = true
      else
        if streak_active && streak_count >= min_length && i < trades.length
          results << trade
        end
        streak_count = outcome == streak_type ? 1 : 0
        streak_active = outcome == streak_type
      end
    end

    return nil if results.empty?
    wins = results.count { |t| t["pnl"].to_f > 0 }
    {
      count: results.count,
      win_rate: (wins.to_f / results.count * 100).round(1),
      avg_pnl: (results.sum { |t| t["pnl"].to_f } / results.count).round(2)
    }
  end

  def max_consecutive(trades, winning)
    max = 0
    current = 0
    trades.each do |t|
      if winning ? t["pnl"].to_f > 0 : t["pnl"].to_f <= 0
        current += 1
        max = current if current > max
      else
        current = 0
      end
    end
    max
  end

  def backtest_strategy(trades, starting_equity, &risk_block)
    equity = starting_equity.to_f
    peak = equity
    max_dd = 0
    curve = []
    wins = 0
    losses = 0
    total_risked = 0

    trades.each_with_index do |trade, i|
      pnl = trade["pnl"].to_f
      entry = trade["entry_price"].to_f
      stop = trade["stop_loss"]&.to_f
      qty = trade["quantity"].to_i

      # Calculate the risk budget from the strategy
      risk_budget = risk_block.call(equity, trade, i)
      risk_budget = [risk_budget, equity * 0.20].min # Cap at 20% of equity
      risk_budget = [risk_budget, 0].max

      # Scale the trade's P&L by the ratio of strategy risk to actual risk
      actual_risk = if stop && stop > 0 && entry > 0 && qty > 0
                      (entry - stop).abs * qty
                    else
                      @avg_loss > 0 ? @avg_loss : equity * 0.01
                    end
      actual_risk = [actual_risk, 1].max

      scale = risk_budget / actual_risk
      scaled_pnl = pnl * scale

      equity += scaled_pnl
      equity = [equity, 0].max
      total_risked += risk_budget

      peak = equity if equity > peak
      dd = peak > 0 ? ((peak - equity) / peak * 100) : 0
      max_dd = dd if dd > max_dd

      wins += 1 if scaled_pnl > 0
      losses += 1 if scaled_pnl < 0

      curve << { trade: i + 1, equity: equity.round(2) }
    end

    total = wins + losses
    {
      curve: curve,
      final_equity: equity.round(2),
      total_return: starting_equity > 0 ? ((equity - starting_equity) / starting_equity * 100).round(1) : 0,
      max_drawdown: max_dd.round(1),
      win_rate: total > 0 ? (wins.to_f / total * 100).round(1) : 0,
      trades: total,
      avg_risk: total > 0 ? (total_risked / total).round(2) : 0,
      sharpe: curve.length >= 2 ? compute_sharpe(curve) : 0
    }
  end

  def compute_sharpe(curve)
    returns = curve.each_cons(2).map { |a, b| b[:equity] - a[:equity] }
    return 0 if returns.empty?
    avg = returns.sum / returns.count
    stddev = Math.sqrt(returns.map { |r| (r - avg) ** 2 }.sum / returns.count)
    stddev > 0 ? (avg / stddev * Math.sqrt(252)).round(2) : 0
  end

  def pearson_correlation(x, y)
    n = x.length
    return nil if n < 3

    sum_x = x.sum.to_f
    sum_y = y.sum.to_f
    sum_xy = x.zip(y).sum { |a, b| a * b }
    sum_x2 = x.sum { |v| v**2 }
    sum_y2 = y.sum { |v| v**2 }

    numerator = n * sum_xy - sum_x * sum_y
    denominator = Math.sqrt((n * sum_x2 - sum_x**2) * (n * sum_y2 - sum_y**2))

    return 0.0 if denominator.zero?
    (numerator / denominator).round(3)
  end

  def compute_period_stats(trades)
    trades = trades.sort_by { |t| t["entry_time"].to_s }
    pnls = trades.map { |t| t["pnl"].to_f }
    winners = pnls.select { |p| p > 0 }
    losers  = pnls.select { |p| p < 0 }

    trade_count = trades.count
    win_count   = winners.count
    loss_count  = losers.count
    total_pnl   = pnls.sum.round(2)
    avg_pnl     = trade_count > 0 ? (total_pnl / trade_count).round(2) : 0
    win_rate    = trade_count > 0 ? (win_count.to_f / trade_count * 100).round(1) : 0
    avg_win     = winners.any? ? (winners.sum / winners.count).round(2) : 0
    avg_loss    = losers.any? ? (losers.sum / losers.count).round(2) : 0
    best_trade  = pnls.max || 0
    worst_trade = pnls.min || 0
    gross_wins  = winners.sum.round(2)
    gross_losses = losers.sum.abs.round(2)
    profit_factor = gross_losses > 0 ? (gross_wins / gross_losses).round(2) : 0

    # Hold time (average minutes)
    hold_times = trades.filter_map { |t|
      entry = t["entry_time"].to_s
      exit_t = t["exit_time"].to_s
      next unless entry.present? && exit_t.present?
      begin
        ((Time.parse(exit_t) - Time.parse(entry)) / 60.0).round
      rescue
        nil
      end
    }
    avg_hold_minutes = hold_times.any? ? (hold_times.sum.to_f / hold_times.count).round(0) : 0

    # Most traded symbol
    symbol_counts = trades.group_by { |t| t["symbol"] }.transform_values(&:count)
    most_traded_symbol = symbol_counts.max_by { |_, c| c }&.first || "N/A"

    # Daily P&L for charts
    daily_pnl = {}
    trades.each do |t|
      date = t["entry_time"]&.to_s&.slice(0, 10)
      next unless date
      daily_pnl[date] = (daily_pnl[date] || 0) + t["pnl"].to_f
    end
    daily_pnl.transform_values! { |v| v.round(2) }

    # Max drawdown
    peak = 0
    max_dd = 0
    cumulative = 0
    pnls.each do |p|
      cumulative += p
      peak = cumulative if cumulative > peak
      dd = peak > 0 ? ((peak - cumulative) / peak * 100) : 0
      max_dd = dd if dd > max_dd
    end

    # Equity curve
    equity_curve = []
    running = 0
    pnls.each_with_index do |p, i|
      running += p
      equity_curve << { trade: i + 1, equity: running.round(2) }
    end

    {
      trade_count: trade_count,
      win_count: win_count,
      loss_count: loss_count,
      win_rate: win_rate,
      total_pnl: total_pnl,
      avg_pnl: avg_pnl,
      avg_win: avg_win,
      avg_loss: avg_loss,
      best_trade: best_trade.round(2),
      worst_trade: worst_trade.round(2),
      profit_factor: profit_factor,
      avg_hold_minutes: avg_hold_minutes,
      most_traded_symbol: most_traded_symbol,
      daily_pnl: daily_pnl,
      max_drawdown: max_dd.round(1),
      equity_curve: equity_curve,
      gross_wins: gross_wins,
      gross_losses: gross_losses
    }
  end

  def compute_deltas(p1, p2)
    deltas = {}
    [
      { key: :trade_count,    label: "Trade Count",        format: :number,   positive_better: true },
      { key: :win_rate,       label: "Win Rate",           format: :percent,  positive_better: true },
      { key: :total_pnl,     label: "Total P&L",          format: :currency, positive_better: true },
      { key: :avg_pnl,       label: "Avg P&L",            format: :currency, positive_better: true },
      { key: :avg_win,       label: "Avg Win",            format: :currency, positive_better: true },
      { key: :avg_loss,      label: "Avg Loss",           format: :currency, positive_better: false },
      { key: :best_trade,    label: "Best Trade",         format: :currency, positive_better: true },
      { key: :worst_trade,   label: "Worst Trade",        format: :currency, positive_better: false },
      { key: :profit_factor, label: "Profit Factor",      format: :decimal,  positive_better: true },
      { key: :max_drawdown,  label: "Max Drawdown",       format: :percent,  positive_better: false },
      { key: :avg_hold_minutes, label: "Avg Hold Time",   format: :minutes,  positive_better: nil }
    ].each do |m|
      v1 = p1[m[:key]].to_f
      v2 = p2[m[:key]].to_f
      diff = v1 - v2
      pct_change = v2 != 0 ? ((diff / v2.abs) * 100).round(1) : (diff != 0 ? 100.0 : 0)
      improved = if m[:positive_better].nil?
                   nil
                 elsif m[:positive_better]
                   diff > 0
                 else
                   diff < 0
                 end
      deltas[m[:key]] = {
        label: m[:label],
        format: m[:format],
        v1: v1,
        v2: v2,
        diff: diff.round(2),
        pct_change: pct_change,
        improved: improved,
        positive_better: m[:positive_better]
      }
    end
    deltas
  end
end

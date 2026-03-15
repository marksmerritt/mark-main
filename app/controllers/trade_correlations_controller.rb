class TradeCorrelationsController < ApplicationController
  before_action :require_api_connection

  def show
    result = begin
      api_client.trades(per_page: 1000)
    rescue => e
      Rails.logger.error("TradeCorrelations: failed to fetch trades: #{e.message}")
      nil
    end

    all_trades = if result.is_a?(Hash)
      result["trades"] || []
    else
      Array(result)
    end
    all_trades = all_trades.select { |t| t.is_a?(Hash) }

    # Filter to closed trades with P&L and dates
    closed_trades = all_trades.select { |t|
      t["status"] != "open" &&
        t["pnl"].to_f != 0 &&
        (t["exit_time"] || t["entry_time"]).present? &&
        t["symbol"].present?
    }

    # Group by symbol, require 5+ trades
    grouped = closed_trades.group_by { |t| t["symbol"].upcase }
    grouped = grouped.select { |_, trades| trades.count >= 5 }

    @symbols = grouped.keys.sort
    @symbol_count = @symbols.count

    # Build daily P&L per symbol: { symbol => { date => total_pnl } }
    @daily_pnl = {}
    grouped.each do |sym, trades|
      @daily_pnl[sym] = {}
      trades.each do |t|
        date = (t["exit_time"] || t["entry_time"]).to_s.slice(0, 10)
        next unless date.present?
        @daily_pnl[sym][date] ||= 0.0
        @daily_pnl[sym][date] += t["pnl"].to_f
      end
    end

    # Compute correlation matrix
    @correlation_matrix = {}
    @symbols.each do |s1|
      @correlation_matrix[s1] = {}
      @symbols.each do |s2|
        if s1 == s2
          @correlation_matrix[s1][s2] = 1.0
        else
          @correlation_matrix[s1][s2] = pearson_correlation(@daily_pnl[s1], @daily_pnl[s2])
        end
      end
    end

    # Highly correlated pairs (> 0.5)
    @correlated_pairs = []
    @symbols.each_with_index do |s1, i|
      @symbols[(i + 1)..].each do |s2|
        corr = @correlation_matrix[s1][s2]
        next unless corr
        if corr > 0.5
          @correlated_pairs << { pair: [s1, s2], correlation: corr.round(3) }
        end
      end
    end
    @correlated_pairs.sort_by! { |p| -p[:correlation] }

    # Inversely correlated pairs (< -0.3)
    @inverse_pairs = []
    @symbols.each_with_index do |s1, i|
      @symbols[(i + 1)..].each do |s2|
        corr = @correlation_matrix[s1][s2]
        next unless corr
        if corr < -0.3
          @inverse_pairs << { pair: [s1, s2], correlation: corr.round(3) }
        end
      end
    end
    @inverse_pairs.sort_by! { |p| p[:correlation] }

    # Diversification score (lower avg pairwise correlation = better diversified)
    all_correlations = []
    @symbols.each_with_index do |s1, i|
      @symbols[(i + 1)..].each do |s2|
        corr = @correlation_matrix[s1][s2]
        all_correlations << corr if corr
      end
    end
    @avg_correlation = all_correlations.any? ? (all_correlations.sum / all_correlations.count.to_f).round(3) : 0
    # Score from 0-100, where 0 avg correlation = 100 score, 1.0 avg = 0 score
    @diversification_score = [(100 * (1 - @avg_correlation)).round(0), 0].max
    @diversification_score = [@diversification_score, 100].min

    # Concentration risk: symbols that correlate with many others (> 0.5)
    @concentration_risk = {}
    @symbols.each do |sym|
      correlated_count = @symbols.count { |other|
        next false if sym == other
        c = @correlation_matrix[sym][other]
        c && c > 0.5
      }
      @concentration_risk[sym] = correlated_count if correlated_count > 0
    end
    @concentration_risk = @concentration_risk.sort_by { |_, v| -v }.to_h

    # Best hedge pairs: inversely correlated symbols that could offset risk
    @hedge_pairs = @inverse_pairs.first(10).map { |p|
      s1, s2 = p[:pair]
      pnl1 = grouped[s1]&.sum { |t| t["pnl"].to_f } || 0
      pnl2 = grouped[s2]&.sum { |t| t["pnl"].to_f } || 0
      p.merge(
        pnl1: pnl1.round(2),
        pnl2: pnl2.round(2),
        combined_pnl: (pnl1 + pnl2).round(2)
      )
    }

    # Symbol clusters: group symbols with similar performance patterns
    @clusters = build_clusters(@symbols, @correlation_matrix)

    # Per-symbol stats for context
    @symbol_stats = {}
    grouped.each do |sym, trades|
      total_pnl = trades.sum { |t| t["pnl"].to_f }
      wins = trades.count { |t| t["pnl"].to_f > 0 }
      @symbol_stats[sym] = {
        count: trades.count,
        total_pnl: total_pnl.round(2),
        win_rate: (wins.to_f / trades.count * 100).round(1)
      }
    end
  end

  private

  def pearson_correlation(series_a, series_b)
    return nil if series_a.nil? || series_b.nil?

    # Find overlapping dates
    common_dates = series_a.keys & series_b.keys
    return nil if common_dates.count < 3

    xs = common_dates.map { |d| series_a[d] }
    ys = common_dates.map { |d| series_b[d] }

    n = xs.count.to_f
    mx = xs.sum / n
    my = ys.sum / n

    numerator = 0.0
    denom_x = 0.0
    denom_y = 0.0

    xs.each_with_index do |x, i|
      y = ys[i]
      dx = x - mx
      dy = y - my
      numerator += dx * dy
      denom_x += dx * dx
      denom_y += dy * dy
    end

    return 0.0 if denom_x == 0 || denom_y == 0

    (numerator / Math.sqrt(denom_x * denom_y)).round(4)
  rescue => e
    Rails.logger.error("TradeCorrelations: pearson error: #{e.message}")
    nil
  end

  def build_clusters(symbols, matrix)
    return [] if symbols.count < 2

    # Simple clustering: group symbols that correlate > 0.4 with each other
    assigned = {}
    clusters = []

    symbols.each do |sym|
      next if assigned[sym]

      cluster = [sym]
      assigned[sym] = true

      symbols.each do |other|
        next if other == sym || assigned[other]
        corr = matrix[sym][other]
        next unless corr && corr > 0.4

        # Check this symbol also correlates with existing cluster members
        fits = cluster.all? { |member|
          c = matrix[member][other]
          c && c > 0.2
        }
        if fits
          cluster << other
          assigned[other] = true
        end
      end

      clusters << cluster if cluster.count >= 2
    end

    # Add unclustered symbols as singles
    unclustered = symbols - assigned.keys
    unclustered.each { |sym| clusters << [sym] }

    clusters.sort_by { |c| -c.count }
  end
end

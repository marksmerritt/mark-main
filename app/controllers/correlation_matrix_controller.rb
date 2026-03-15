class CorrelationMatrixController < ApplicationController
  include ApiConnected

  def show
    trades_thread = Thread.new do
      fetch_all_trades
    rescue => e
      Rails.logger.error("correlation_matrix trades: #{e.message}")
      []
    end

    trades = trades_thread.value || []
    closed = trades.select { |t| t["status"] == "closed" || t["exit_price"].present? }

    @symbols = compute_symbol_stats(closed)
    @matrix = compute_correlation_matrix(closed)
    @pairwise = top_correlated_pairs(@matrix, 10)
    @anti_pairs = anti_correlated_pairs(@matrix, 5)
    @diversification_score = compute_diversification(@matrix)
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

  def compute_symbol_stats(trades)
    trades.group_by { |t| t["symbol"] || "Unknown" }.map do |sym, group|
      pnls = group.map { |t| t["pnl"].to_f }
      wins = pnls.count(&:positive?)
      {
        name: sym,
        count: group.length,
        total_pnl: pnls.sum.round(2),
        win_rate: (wins.to_f / [pnls.length, 1].max * 100).round(1),
        avg_pnl: (pnls.sum / [pnls.length, 1].max).round(2)
      }
    end.sort_by { |s| -s[:count] }
  end

  def compute_correlation_matrix(trades)
    # Build daily P&L series for each symbol
    daily_by_symbol = {}
    trades.each do |t|
      sym = t["symbol"] || "Unknown"
      date = (t["closed_at"] || t["created_at"] || "").to_s.slice(0, 10)
      next if date.empty?
      daily_by_symbol[sym] ||= Hash.new(0)
      daily_by_symbol[sym][date] += t["pnl"].to_f
    end

    symbols = daily_by_symbol.keys.select { |s| daily_by_symbol[s].length >= 3 }.sort
    return { symbols: symbols, correlations: {} } if symbols.length < 2

    # Collect all dates
    all_dates = daily_by_symbol.values.flat_map(&:keys).uniq.sort

    # Build vectors
    vectors = {}
    symbols.each do |sym|
      vectors[sym] = all_dates.map { |d| daily_by_symbol[sym][d] }
    end

    # Compute pairwise correlations
    correlations = {}
    symbols.each do |s1|
      correlations[s1] = {}
      symbols.each do |s2|
        correlations[s1][s2] = pearson_correlation(vectors[s1], vectors[s2])
      end
    end

    { symbols: symbols.first(15), correlations: correlations }
  end

  def pearson_correlation(x, y)
    n = x.length
    return 0 if n < 3

    sum_x = x.sum
    sum_y = y.sum
    sum_xy = x.zip(y).sum { |a, b| a * b }
    sum_x2 = x.sum { |a| a * a }
    sum_y2 = y.sum { |b| b * b }

    num = n * sum_xy - sum_x * sum_y
    den = Math.sqrt((n * sum_x2 - sum_x**2) * (n * sum_y2 - sum_y**2))
    return 0 if den == 0
    (num / den).round(3)
  end

  def top_correlated_pairs(matrix, n)
    return [] unless matrix[:correlations].any?
    pairs = []
    syms = matrix[:symbols]
    syms.each_with_index do |s1, i|
      syms[(i+1)..].each do |s2|
        corr = matrix[:correlations].dig(s1, s2) || 0
        pairs << { sym1: s1, sym2: s2, correlation: corr }
      end
    end
    pairs.sort_by { |p| -p[:correlation].abs }.first(n)
  end

  def anti_correlated_pairs(matrix, n)
    return [] unless matrix[:correlations].any?
    pairs = []
    syms = matrix[:symbols]
    syms.each_with_index do |s1, i|
      syms[(i+1)..].each do |s2|
        corr = matrix[:correlations].dig(s1, s2) || 0
        pairs << { sym1: s1, sym2: s2, correlation: corr } if corr < 0
      end
    end
    pairs.sort_by { |p| p[:correlation] }.first(n)
  end

  def compute_diversification(matrix)
    return { score: 100, assessment: "Insufficient data" } unless matrix[:correlations].any?

    syms = matrix[:symbols]
    return { score: 100, assessment: "Single symbol" } if syms.length < 2

    # Average absolute correlation
    total = 0
    count = 0
    syms.each_with_index do |s1, i|
      syms[(i+1)..].each do |s2|
        total += (matrix[:correlations].dig(s1, s2) || 0).abs
        count += 1
      end
    end

    avg_corr = count > 0 ? (total / count) : 0
    score = ((1 - avg_corr) * 100).round(0).clamp(0, 100)

    assessment = case score
                 when 80..100 then "Excellent diversification"
                 when 60..79 then "Good diversification"
                 when 40..59 then "Moderate concentration"
                 else "High concentration risk"
                 end

    { score: score, avg_correlation: avg_corr.round(3), assessment: assessment, symbol_count: syms.length }
  end
end

module PerformanceGradeHelper
  def performance_grade(stats, risk = nil)
    return nil unless stats.is_a?(Hash) && stats["total_trades"].to_i >= 5

    scores = {}

    # Profitability (0-100)
    pnl = stats["total_pnl"].to_f
    scores[:profitability] = if pnl > 0
      [50 + (pnl / 100.0), 100].min.round
    else
      [50 + (pnl / 100.0), 0].max.round
    end

    # Win rate (0-100)
    win_rate = stats["win_rate"].to_f
    scores[:win_rate] = case win_rate
    when 60.. then [80 + (win_rate - 60), 100].min.round
    when 50..60 then (60 + (win_rate - 50) * 2).round
    when 40..50 then (40 + (win_rate - 40) * 2).round
    else [win_rate, 0].max.round
    end

    # Risk management (0-100)
    profit_factor = stats["profit_factor"].to_f
    scores[:risk_management] = case profit_factor
    when 2.. then [85 + (profit_factor - 2) * 5, 100].min.round
    when 1.5..2 then (70 + (profit_factor - 1.5) * 30).round
    when 1..1.5 then (40 + (profit_factor - 1) * 60).round
    else [profit_factor * 40, 0].max.round
    end

    # Consistency (based on avg win vs avg loss ratio)
    avg_win = stats["avg_win"].to_f.abs
    avg_loss = stats["avg_loss"].to_f.abs
    if avg_loss > 0
      payoff = avg_win / avg_loss
      scores[:consistency] = case payoff
      when 2.. then [85 + (payoff - 2) * 5, 100].min.round
      when 1.5..2 then (70 + (payoff - 1.5) * 30).round
      when 1..1.5 then (50 + (payoff - 1) * 40).round
      else [payoff * 50, 0].max.round
      end
    else
      scores[:consistency] = stats["winning_trades"].to_i > 0 ? 80 : 50
    end

    # Discipline (based on risk metrics if available)
    if risk.present? && risk.is_a?(Hash)
      sharpe = risk["sharpe_like"].to_f
      scores[:discipline] = case sharpe
      when 1.. then [80 + (sharpe - 1) * 10, 100].min.round
      when 0.5..1 then (60 + (sharpe - 0.5) * 40).round
      when 0..0.5 then (40 + sharpe * 40).round
      else [20 + sharpe * 20, 0].max.round
      end
    else
      scores[:discipline] = scores.values.sum / scores.values.count
    end

    overall = (scores.values.sum.to_f / scores.values.count).round
    letter = score_to_letter(overall)

    {
      overall: overall,
      letter: letter,
      categories: scores,
      letters: scores.transform_values { |s| score_to_letter(s) }
    }
  end

  def score_to_letter(score)
    case score
    when 90..100 then "A+"
    when 85..89 then "A"
    when 80..84 then "A-"
    when 75..79 then "B+"
    when 70..74 then "B"
    when 65..69 then "B-"
    when 60..64 then "C+"
    when 55..59 then "C"
    when 50..54 then "C-"
    when 40..49 then "D"
    else "F"
    end
  end

  def grade_color_class(letter)
    case letter
    when /^A/ then "grade-a"
    when /^B/ then "grade-b"
    when /^C/ then "grade-c"
    when /^D/ then "grade-d"
    else "grade-f"
    end
  end
end

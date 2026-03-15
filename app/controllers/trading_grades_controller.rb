class TradingGradesController < ApplicationController
  before_action :require_api_connection

  include ActionView::Helpers::NumberHelper

  def show
    threads = {}
    threads[:trades] = Thread.new { api_client.trades(per_page: 2000, status: "closed") }
    threads[:overview] = Thread.new { api_client.overview }
    threads[:streaks] = Thread.new { api_client.streaks rescue {} }

    trade_result = threads[:trades].value
    @trades = trade_result.is_a?(Hash) ? (trade_result["trades"] || []) : Array(trade_result)
    @trades = @trades.select { |t| t.is_a?(Hash) }
    @overview = threads[:overview].value || {}
    @streaks = threads[:streaks].value || {}

    return if @trades.empty?

    @grades = []
    pnls = @trades.map { |t| t["pnl"].to_f }
    wins = @trades.select { |t| t["pnl"].to_f > 0 }
    losses = @trades.select { |t| t["pnl"].to_f < 0 }

    # 1. Win Rate
    win_rate = @trades.any? ? (wins.count.to_f / @trades.count * 100).round(1) : 0
    wr_score = case win_rate
               when 60.. then 95
               when 50..59.9 then 80
               when 40..49.9 then 65
               when 30..39.9 then 45
               else 25
               end
    @grades << { name: "Win Rate", icon: "target", score: wr_score, grade: score_grade(wr_score),
      value: "#{win_rate}%", detail: "#{wins.count}W / #{losses.count}L out of #{@trades.count} trades",
      tip: win_rate >= 50 ? "Strong hit rate. Focus on maintaining consistency." : "Below 50% — improve entry criteria or be more selective." }

    # 2. Risk/Reward
    trades_with_rr = @trades.select { |t| t["stop_loss"].to_f > 0 && t["take_profit"].to_f > 0 && t["entry_price"].to_f > 0 }
    if trades_with_rr.any?
      avg_rr = trades_with_rr.map { |t|
        entry = t["entry_price"].to_f
        stop = t["stop_loss"].to_f
        target = t["take_profit"].to_f
        risk = (entry - stop).abs
        reward = (target - entry).abs
        risk > 0 ? reward / risk : 0
      }.sum / trades_with_rr.count
      rr_score = case avg_rr
                 when 3.. then 95
                 when 2..2.99 then 85
                 when 1.5..1.99 then 70
                 when 1..1.49 then 55
                 else 35
                 end
    else
      avg_rr = 0
      rr_score = 30
    end
    @grades << { name: "Risk/Reward", icon: "balance", score: rr_score, grade: score_grade(rr_score),
      value: "#{avg_rr.round(2)}:1", detail: "#{trades_with_rr.count} trades with defined R:R",
      tip: avg_rr >= 2 ? "Excellent risk/reward ratios." : trades_with_rr.empty? ? "Set stop losses and targets for every trade." : "Aim for at least 2:1 reward-to-risk." }

    # 3. Risk Management (stop loss usage)
    trades_with_stops = @trades.count { |t| t["stop_loss"].to_f > 0 }
    stop_pct = @trades.any? ? (trades_with_stops.to_f / @trades.count * 100).round(1) : 0
    rm_score = case stop_pct
               when 90.. then 95
               when 70..89 then 75
               when 50..69 then 55
               when 30..49 then 35
               else 15
               end
    @grades << { name: "Risk Management", icon: "shield", score: rm_score, grade: score_grade(rm_score),
      value: "#{stop_pct}% with stops", detail: "#{trades_with_stops}/#{@trades.count} trades used stop losses",
      tip: stop_pct >= 90 ? "Excellent discipline with stop losses." : "Always use stop losses. #{@trades.count - trades_with_stops} trades had no stop." }

    # 4. Profit Factor
    gross_profit = wins.sum { |t| t["pnl"].to_f }
    gross_loss = losses.sum { |t| t["pnl"].to_f.abs }
    profit_factor = gross_loss > 0 ? (gross_profit / gross_loss).round(2) : (gross_profit > 0 ? 99 : 0)
    pf_score = case profit_factor
               when 2.. then 95
               when 1.5..1.99 then 80
               when 1.2..1.49 then 65
               when 1..1.19 then 50
               else 25
               end
    @grades << { name: "Profit Factor", icon: "paid", score: pf_score, grade: score_grade(pf_score),
      value: profit_factor.to_s, detail: "#{number_to_currency(gross_profit)} won / #{number_to_currency(gross_loss)} lost",
      tip: profit_factor >= 1.5 ? "Strong edge — winning more than losing." : profit_factor >= 1 ? "Slightly profitable but thin edge. Reduce losses." : "Losing edge. Review strategy and cut losses faster." }

    # 5. Consistency
    monthly_pnl = {}
    @trades.each do |t|
      month = (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 7)
      next unless month
      monthly_pnl[month] ||= 0
      monthly_pnl[month] += t["pnl"].to_f
    end
    profitable_months = monthly_pnl.values.count { |v| v > 0 }
    total_months = [monthly_pnl.count, 1].max
    month_win_pct = (profitable_months.to_f / total_months * 100).round(1)
    cons_score = case month_win_pct
                 when 80.. then 95
                 when 60..79 then 75
                 when 40..59 then 55
                 else 30
                 end
    @grades << { name: "Consistency", icon: "straighten", score: cons_score, grade: score_grade(cons_score),
      value: "#{month_win_pct}% months profitable", detail: "#{profitable_months}/#{total_months} profitable months",
      tip: month_win_pct >= 70 ? "Very consistent month-to-month." : "Work on reducing monthly variance. Smaller position sizes help." }

    # 6. Drawdown Management
    running = 0
    peak = 0
    max_dd = 0
    @trades.sort_by { |t| t["exit_time"] || t["entry_time"] || "" }.each do |t|
      running += t["pnl"].to_f
      peak = running if running > peak
      dd = peak - running
      max_dd = dd if dd > max_dd
    end
    total_pnl = pnls.sum
    dd_pct = peak > 0 ? (max_dd / peak * 100).round(1) : 0
    dd_score = case dd_pct
               when 0..10 then 95
               when 10..20 then 80
               when 20..30 then 60
               when 30..50 then 40
               else 20
               end
    @grades << { name: "Drawdown Control", icon: "trending_down", score: dd_score, grade: score_grade(dd_score),
      value: "#{dd_pct}% max DD", detail: "Max drawdown: #{number_to_currency(max_dd)} from peak of #{number_to_currency(peak)}",
      tip: dd_pct <= 15 ? "Excellent capital preservation." : "Reduce position sizes during losing streaks to limit drawdowns." }

    # 7. Trade Sizing
    position_sizes = @trades.filter_map { |t|
      entry = t["entry_price"].to_f
      qty = t["quantity"].to_f
      entry > 0 && qty > 0 ? entry * qty : nil
    }
    if position_sizes.length >= 5
      avg_size = position_sizes.sum / position_sizes.count
      std_dev = Math.sqrt(position_sizes.map { |s| (s - avg_size) ** 2 }.sum / position_sizes.count)
      cv = avg_size > 0 ? (std_dev / avg_size * 100).round(1) : 0
      sizing_score = case cv
                     when 0..20 then 95
                     when 20..40 then 80
                     when 40..60 then 60
                     else 35
                     end
    else
      cv = 0
      sizing_score = 50
    end
    @grades << { name: "Position Sizing", icon: "tune", score: sizing_score, grade: score_grade(sizing_score),
      value: "#{cv}% variance", detail: position_sizes.any? ? "Avg position: #{number_to_currency(position_sizes.sum / position_sizes.count)}" : "Not enough data",
      tip: cv <= 30 ? "Consistent position sizing — great discipline." : "Position sizes vary too much. Standardize your sizing rules." }

    # 8. Journaling Discipline
    journal_streak = @streaks.is_a?(Hash) ? (@streaks["journal_streak"] || @streaks["current_journal_streak"] || 0).to_i : 0
    journal_score = case journal_streak
                    when 14.. then 95
                    when 7..13 then 80
                    when 3..6 then 60
                    when 1..2 then 40
                    else 20
                    end
    @grades << { name: "Journal Discipline", icon: "edit_note", score: journal_score, grade: score_grade(journal_score),
      value: "#{journal_streak}-day streak", detail: "Current journaling streak",
      tip: journal_streak >= 7 ? "Great journaling habit!" : "Journal every trading day to build self-awareness." }

    # Overall
    @overall_score = (@grades.sum { |g| g[:score] } / @grades.count.to_f).round(0)
    @overall_grade = score_grade(@overall_score)

    # Best and worst dimensions
    @strongest = @grades.max_by { |g| g[:score] }
    @weakest = @grades.min_by { |g| g[:score] }
  end

  private

  def score_grade(score)
    case score
    when 90..100 then "A"
    when 80..89 then "B"
    when 65..79 then "C"
    when 50..64 then "D"
    else "F"
    end
  end
end

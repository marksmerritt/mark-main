class WritingGoalsController < ApplicationController
  before_action :require_notes_connection

  include ActionView::Helpers::NumberHelper

  def show
    notes_result = notes_client.notes(per_page: 1000) rescue []
    @notes = notes_result.is_a?(Hash) ? (notes_result["notes"] || []) : Array(notes_result)
    @notes = @notes.select { |n| n.is_a?(Hash) }

    # Word counts per note
    @notes.each do |n|
      content = n["content"] || n["body"] || ""
      n["_word_count"] = content.split(/\s+/).reject(&:blank?).count
    end

    # Parse dates for each note
    @notes.each do |n|
      n["_created_date"] = Date.parse(n["created_at"] || n["updated_at"] || "") rescue nil
      n["_updated_date"] = Date.parse(n["updated_at"] || n["created_at"] || "") rescue nil
    end

    today = Date.current
    beginning_of_week = today.beginning_of_week(:monday)
    beginning_of_month = today.beginning_of_month

    # --- Goal defaults ---
    @daily_word_goal = 500
    @weekly_word_goal = 3000
    @monthly_word_goal = 10000
    @notes_per_week_goal = 5
    @streak_goal = 7
    @notebook_goal = 3

    # --- Today's progress ---
    @today_notes = @notes.select { |n| n["_created_date"] == today || n["_updated_date"] == today }
    @today_words = @today_notes.sum { |n| n["_word_count"] }
    @daily_progress = @daily_word_goal > 0 ? [(@today_words.to_f / @daily_word_goal * 100).round(1), 100].min : 0

    # --- Weekly progress ---
    @week_notes = @notes.select { |n| d = n["_created_date"]; d && d >= beginning_of_week && d <= today }
    @week_words = @week_notes.sum { |n| n["_word_count"] }
    @weekly_progress = @weekly_word_goal > 0 ? [(@week_words.to_f / @weekly_word_goal * 100).round(1), 100].min : 0
    @week_note_count = @week_notes.count
    @notes_per_week_progress = @notes_per_week_goal > 0 ? [(@week_note_count.to_f / @notes_per_week_goal * 100).round(1), 100].min : 0

    # --- Monthly progress ---
    @month_notes = @notes.select { |n| d = n["_created_date"]; d && d >= beginning_of_month && d <= today }
    @month_words = @month_notes.sum { |n| n["_word_count"] }
    @monthly_progress = @monthly_word_goal > 0 ? [(@month_words.to_f / @monthly_word_goal * 100).round(1), 100].min : 0

    # --- Notebook diversity this week ---
    @week_notebooks = @week_notes.map { |n| n.dig("notebook", "name") || "No Notebook" }.uniq
    @notebook_count = @week_notebooks.count
    @notebook_progress = @notebook_goal > 0 ? [(@notebook_count.to_f / @notebook_goal * 100).round(1), 100].min : 0

    # --- Writing streak ---
    sorted_dates = @notes.filter_map { |n| n["_created_date"] }.uniq.sort
    @writing_streak = 0
    if sorted_dates.any?
      current = today
      while sorted_dates.include?(current)
        @writing_streak += 1
        current -= 1
      end
    end
    @streak_progress = @streak_goal > 0 ? [(@writing_streak.to_f / @streak_goal * 100).round(1), 100].min : 0

    # --- Daily word counts for last 30 days ---
    @daily_words = {}
    (today - 29..today).each { |d| @daily_words[d] = 0 }
    @notes.each do |n|
      d = n["_created_date"]
      next unless d && @daily_words.key?(d)
      @daily_words[d] += n["_word_count"]
    end

    # --- 30-day goal tracking ---
    @days_goal_met = @daily_words.count { |_, words| words >= @daily_word_goal }
    @days_goal_missed = @daily_words.count { |_, words| words < @daily_word_goal }
    @success_rate = @daily_words.any? ? ((@days_goal_met.to_f / @daily_words.count) * 100).round(1) : 0

    # --- Weekly performance for current week (Mon-Sun) ---
    @week_daily = {}
    (beginning_of_week..today).each { |d| @week_daily[d] = 0 }
    @week_notes.each do |n|
      d = n["_created_date"]
      @week_daily[d] = (@week_daily[d] || 0) + n["_word_count"] if d && @week_daily.key?(d)
    end

    # --- Historical performance: best week/month ---
    weekly_totals = {}
    monthly_totals = {}
    @notes.each do |n|
      d = n["_created_date"]
      next unless d
      week_key = d.beginning_of_week(:monday)
      monthly_key = d.beginning_of_month
      weekly_totals[week_key] = (weekly_totals[week_key] || 0) + n["_word_count"]
      monthly_totals[monthly_key] = (monthly_totals[monthly_key] || 0) + n["_word_count"]
    end
    @best_week = weekly_totals.max_by { |_, v| v }
    @best_month = monthly_totals.max_by { |_, v| v }

    # --- Trends: compare last 15 days vs prior 15 days ---
    recent_15 = @daily_words.to_a.last(15)
    prior_15 = @daily_words.to_a.first(15)
    @recent_avg = recent_15.any? ? (recent_15.sum { |_, w| w }.to_f / recent_15.count).round(0) : 0
    @prior_avg = prior_15.any? ? (prior_15.sum { |_, w| w }.to_f / prior_15.count).round(0) : 0
    @trend_direction = @recent_avg >= @prior_avg ? "up" : "down"
    @trend_delta = (@recent_avg - @prior_avg).abs

    # --- Goal success rates by type ---
    weekly_goal_met_count = weekly_totals.count { |_, w| w >= @weekly_word_goal }
    weekly_goal_total = [weekly_totals.count, 1].max
    @weekly_success_rate = ((weekly_goal_met_count.to_f / weekly_goal_total) * 100).round(1)

    monthly_goal_met_count = monthly_totals.count { |_, w| w >= @monthly_word_goal }
    monthly_goal_total = [monthly_totals.count, 1].max
    @monthly_success_rate = ((monthly_goal_met_count.to_f / monthly_goal_total) * 100).round(1)

    # --- Suggested goal adjustments ---
    actual_daily_avg = @daily_words.values.sum > 0 ? (@daily_words.values.sum.to_f / @daily_words.count).round(0) : 0
    @suggested_daily = suggest_goal(actual_daily_avg, @daily_word_goal)

    actual_weekly_avg = weekly_totals.any? ? (weekly_totals.values.sum.to_f / weekly_totals.count).round(0) : 0
    @suggested_weekly = suggest_goal(actual_weekly_avg, @weekly_word_goal)

    actual_monthly_avg = monthly_totals.any? ? (monthly_totals.values.sum.to_f / monthly_totals.count).round(0) : 0
    @suggested_monthly = suggest_goal(actual_monthly_avg, @monthly_word_goal)

    @actual_daily_avg = actual_daily_avg
    @actual_weekly_avg = actual_weekly_avg
    @actual_monthly_avg = actual_monthly_avg

    # --- Achievements ---
    @achievements = []
    @achievements << { icon: "local_fire_department", label: "7-Day Streak", desc: "Wrote every day for a week" } if @writing_streak >= 7
    @achievements << { icon: "whatshot", label: "14-Day Streak", desc: "Two weeks of daily writing" } if @writing_streak >= 14
    @achievements << { icon: "military_tech", label: "30-Day Streak", desc: "A full month of daily writing" } if @writing_streak >= 30
    @achievements << { icon: "emoji_events", label: "1K Day", desc: "Wrote 1,000+ words in a single day" } if @daily_words.values.any? { |w| w >= 1000 }
    @achievements << { icon: "star", label: "5K Week", desc: "Wrote 5,000+ words in a week" } if weekly_totals.values.any? { |w| w >= 5000 }
    @achievements << { icon: "workspace_premium", label: "10K Month", desc: "Wrote 10,000+ words in a month" } if monthly_totals.values.any? { |w| w >= 10000 }
    @achievements << { icon: "diversity_3", label: "Notebook Explorer", desc: "Used 5+ notebooks in a week" } if @notebook_count >= 5
    @achievements << { icon: "done_all", label: "Goal Crusher", desc: "Met daily goal 20+ of last 30 days" } if @days_goal_met >= 20
    @achievements << { icon: "trending_up", label: "On the Rise", desc: "Output trending upward" } if @trend_direction == "up" && @trend_delta > 50
  end

  private

  def suggest_goal(actual_avg, current_goal)
    return current_goal if actual_avg == 0
    if actual_avg >= current_goal * 1.3
      { value: (actual_avg * 1.1).round(-1), direction: "increase", reason: "You consistently exceed this goal" }
    elsif actual_avg < current_goal * 0.5
      { value: (actual_avg * 1.2).round(-1), direction: "decrease", reason: "This goal may be too ambitious right now" }
    else
      { value: current_goal, direction: "keep", reason: "This goal is well-calibrated" }
    end
  end
end

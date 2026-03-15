class DailyReviewController < ApplicationController
  include ActionView::Helpers::NumberHelper

  def show
    @date = params[:date].present? ? Date.parse(params[:date]) : Date.current
    @yesterday = @date - 1.day
    threads = {}

    if api_token.present?
      threads[:today_trades] = Thread.new {
        result = api_client.trades(
          start_date: @date.to_s,
          end_date: (@date + 1.day).to_s,
          per_page: 50
        )
        result.is_a?(Hash) ? (result["trades"] || []) : Array(result)
      }
      threads[:yesterday_trades] = Thread.new {
        result = api_client.trades(
          start_date: @yesterday.to_s,
          end_date: @date.to_s,
          per_page: 50
        )
        result.is_a?(Hash) ? (result["trades"] || []) : Array(result)
      }
      threads[:journal] = Thread.new {
        result = api_client.journal_entries(
          start_date: @date.to_s,
          end_date: @date.to_s
        )
        result.is_a?(Hash) ? (result["journal_entries"] || []) : Array(result)
      }
      threads[:review_queue] = Thread.new { api_client.review_queue rescue {} }
      threads[:streaks] = Thread.new { api_client.streaks rescue {} }
    end

    if notes_api_token.present?
      threads[:reminders] = Thread.new { notes_client.reminders_due_today rescue [] }
    end

    if budget_api_token.present?
      threads[:recurring] = Thread.new { budget_client.recurring_summary rescue {} }
      threads[:budget] = Thread.new { budget_client.budget_overview rescue {} }
    end

    @today_trades = threads[:today_trades]&.value || []
    @yesterday_trades = threads[:yesterday_trades]&.value || []
    @journal_entries = threads[:journal]&.value || []
    review_result = threads[:review_queue]&.value || {}
    @unreviewed_count = review_result.is_a?(Hash) ? (review_result["count"] || 0) : 0
    @streaks = threads[:streaks]&.value || {}
    reminders_result = threads[:reminders]&.value || []
    @reminders = reminders_result.is_a?(Array) ? reminders_result : (reminders_result.is_a?(Hash) ? (reminders_result["reminders"] || []) : [])
    recurring_result = threads[:recurring]&.value || {}
    @upcoming_bills = recurring_result.is_a?(Hash) ? (recurring_result["upcoming"] || []) : []
    @budget_overview = threads[:budget]&.value || {}

    compute_checklist
  end

  private

  def compute_checklist
    @checklist = []

    # Journal check
    @checklist << {
      label: "Write journal entry",
      done: @journal_entries.any?,
      icon: "auto_stories",
      action_path: @journal_entries.any? ? nil : "/journal_entries/new",
      action_label: "Write"
    }

    # Review trades
    if @unreviewed_count > 0
      @checklist << {
        label: "Review #{@unreviewed_count} unreviewed trade#{'s' if @unreviewed_count != 1}",
        done: false,
        icon: "rate_review",
        action_path: "/trades/review",
        action_label: "Review"
      }
    end

    # Review yesterday's trades
    if @yesterday_trades.any?
      @checklist << {
        label: "Review yesterday's #{@yesterday_trades.count} trade#{'s' if @yesterday_trades.count != 1}",
        done: false,
        icon: "history",
        action_path: nil,
        action_label: nil
      }
    end

    # Check reminders
    if @reminders.any?
      @checklist << {
        label: "#{@reminders.count} reminder#{'s' if @reminders.count != 1} due today",
        done: false,
        icon: "alarm",
        action_path: "/reminders",
        action_label: "View"
      }
    end

    # Upcoming bills
    upcoming_today = @upcoming_bills.select { |b|
      due = Date.parse(b["next_date"] || b["next_due_date"]) rescue nil
      due && due == @date
    }
    if upcoming_today.any?
      @checklist << {
        label: "#{upcoming_today.count} bill#{'s' if upcoming_today.count != 1} due today",
        done: false,
        icon: "receipt",
        action_path: "/budget/recurring",
        action_label: "View"
      }
    end
  end
end

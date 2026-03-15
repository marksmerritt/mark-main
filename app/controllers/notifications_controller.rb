class NotificationsController < ApplicationController
  def index
    items = []
    threads = {}

    if budget_api_token.present?
      threads[:alerts] = Thread.new { budget_client.alerts(status: "unread") rescue {} }
      threads[:recurring] = Thread.new { budget_client.recurring_summary rescue {} }
    end

    if api_token.present?
      threads[:review] = Thread.new { api_client.review_queue rescue {} }
      threads[:streaks] = Thread.new { api_client.streaks rescue {} }
    end

    if notes_api_token.present?
      threads[:reminders] = Thread.new { notes_client.reminders_due_today rescue [] }
    end

    # Budget alerts
    if threads[:alerts]
      result = threads[:alerts].value
      alerts = result.is_a?(Hash) ? (result["alerts"] || []) : Array(result)
      alerts.first(5).each do |alert|
        items << {
          type: "budget_alert",
          icon: severity_icon(alert["severity"]),
          title: alert["title"],
          message: alert["message"],
          severity: alert["severity"] || "info",
          time: alert["created_at"],
          url: "/budget/alerts",
          id: alert["id"]
        }
      end
    end

    # Upcoming bills (due within 3 days)
    if threads[:recurring]
      result = threads[:recurring].value
      upcoming = result.is_a?(Hash) ? (result["upcoming"] || []) : []
      upcoming.each do |bill|
        due_date = Date.parse(bill["next_date"] || bill["next_due_date"]) rescue nil
        next unless due_date
        days_until = (due_date - Date.current).to_i
        next unless days_until.between?(0, 3)
        items << {
          type: "bill_due",
          icon: "receipt",
          title: "#{bill["description"] || bill["name"]} due #{days_until == 0 ? 'today' : "in #{days_until}d"}",
          message: "$#{'%.2f' % bill["amount"].to_f}",
          severity: days_until == 0 ? "warning" : "info",
          time: due_date.to_s,
          url: "/budget/recurring"
        }
      end
    end

    # Unreviewed trades
    if threads[:review]
      result = threads[:review].value
      count = result.is_a?(Hash) ? (result["count"] || (result["trades"]&.count) || 0) : 0
      if count > 0
        items << {
          type: "review",
          icon: "rate_review",
          title: "#{count} unreviewed trade#{'s' if count != 1}",
          message: "Review your recent trades to improve",
          severity: "info",
          url: "/trades/review"
        }
      end
    end

    # Streak alerts
    if threads[:streaks]
      streaks = threads[:streaks].value
      if streaks.is_a?(Hash)
        if streaks["current_losing_day_streak"].to_i >= 3
          items << {
            type: "streak",
            icon: "warning",
            title: "#{streaks["current_losing_day_streak"]}-day losing streak",
            message: "Consider reviewing your strategy",
            severity: "danger"
          }
        end
        if streaks["journal_entry_streak"].to_i >= 7
          items << {
            type: "streak",
            icon: "local_fire_department",
            title: "#{streaks["journal_entry_streak"]}-day journal streak!",
            message: "Keep the consistency going",
            severity: "success"
          }
        end
      end
    end

    # Due reminders
    if threads[:reminders]
      result = threads[:reminders].value
      reminders = result.is_a?(Array) ? result : (result.is_a?(Hash) ? (result["reminders"] || []) : [])
      reminders.first(3).each do |reminder|
        items << {
          type: "reminder",
          icon: "alarm",
          title: reminder["message"].presence || "Reminder",
          message: "Due today",
          severity: "info",
          url: "/reminders"
        }
      end
    end

    @notifications = items

    respond_to do |format|
      format.html
      format.json { render json: { notifications: items, count: items.count } }
    end
  end

  private

  def severity_icon(severity)
    case severity
    when "danger" then "error"
    when "warning" then "warning"
    when "success" then "check_circle"
    else "info"
    end
  end
end

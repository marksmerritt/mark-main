module Budget
  class AlertsController < ApplicationController
    before_action :require_budget_connection

    def index
      # Generate new alerts on page load
      budget_client.generate_alerts
      result = budget_client.alerts
      @alerts = result["alerts"] || []
      @unread_count = result["unread_count"] || 0
    end

    def mark_read
      if params[:id]
        budget_client.mark_alert_read(params[:id])
      else
        budget_client.mark_all_alerts_read
      end
      redirect_to budget_alerts_path, notice: "Marked as read."
    end

    def acknowledge
      budget_client.acknowledge_alert(params[:id])
      redirect_to budget_alerts_path, notice: "Alert acknowledged."
    end

    def destroy
      budget_client.delete_alert(params[:id])
      redirect_to budget_alerts_path, notice: "Alert dismissed."
    end

    def clear
      budget_client.clear_read_alerts
      redirect_to budget_alerts_path, notice: "Read alerts cleared."
    end
  end
end

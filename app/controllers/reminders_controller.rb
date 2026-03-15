class RemindersController < ApplicationController
  before_action :require_notes_connection

  def index
    filter = params[:filter] || "upcoming"
    @reminders = notes_client.reminders(filter: filter)
    @reminders = @reminders["reminders"] || @reminders if @reminders.is_a?(Hash)
    @filter = filter
  end

  def create
    result = notes_client.create_reminder(reminder_params)
    if result["id"]
      redirect_back fallback_location: reminders_path, notice: "Reminder created."
    else
      redirect_back fallback_location: reminders_path, alert: result["message"] || "Failed to create reminder."
    end
  end

  def update
    result = notes_client.update_reminder(params[:id], reminder_params)
    redirect_back fallback_location: reminders_path, notice: "Reminder updated."
  end

  def destroy
    notes_client.delete_reminder(params[:id])
    redirect_back fallback_location: reminders_path, notice: "Reminder deleted."
  end

  private

  def reminder_params
    params.require(:reminder).permit(:note_id, :remind_at, :message, :completed).to_h.compact_blank
  end
end

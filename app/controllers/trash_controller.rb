class TrashController < ApplicationController
  before_action :require_notes_connection

  def index
    result = notes_client.trash
    @notes = result.is_a?(Array) ? result : (result["notes"] || [])
  end

  def restore
    notes_client.restore_note(params[:id])
    redirect_to trash_index_path, notice: "Note restored."
  end

  def empty
    notes_client.empty_trash
    redirect_to trash_index_path, notice: "Trash emptied."
  end
end

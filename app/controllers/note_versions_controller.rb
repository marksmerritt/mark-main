class NoteVersionsController < ApplicationController
  before_action :require_notes_connection

  def index
    @note = notes_client.note(params[:note_id])
    result = notes_client.note_versions(params[:note_id])
    @versions = result["versions"] || result
  end

  def show
    @note = notes_client.note(params[:note_id])
    @version = notes_client.note_version(params[:note_id], params[:id])
  end

  def revert
    notes_client.revert_note(params[:note_id], params[:id])
    redirect_to note_path(params[:note_id]), notice: "Note reverted successfully."
  end
end

class SharedNotesController < ApplicationController
  layout "shared"

  def show
    @note = NotesApiClient.new(nil).shared_note(params[:shared_token])

    if @note.nil? || @note["error"]
      render :not_found, status: :not_found
    end
  end
end

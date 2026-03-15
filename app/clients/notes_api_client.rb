require "net/http"

class NotesApiClient
  BASE_URL = ENV.fetch("NOTES_API_URL", "http://localhost:3002")

  def initialize(token)
    @token = token
  end

  # Notebooks

  def notebooks(params = {})            = get("/api/v1/notebooks", params)
  def notebook(id)                       = get("/api/v1/notebooks/#{id}")
  def create_notebook(attrs)             = post("/api/v1/notebooks", notebook: attrs)
  def update_notebook(id, attrs)         = patch("/api/v1/notebooks/#{id}", notebook: attrs)
  def delete_notebook(id)                = delete("/api/v1/notebooks/#{id}")

  # Notes

  def notes(params = {})                = get("/api/v1/notes", params)
  def note(id)                           = get("/api/v1/notes/#{id}")
  def create_note(attrs)                 = post("/api/v1/notes", note: attrs)
  def update_note(id, attrs)             = patch("/api/v1/notes/#{id}", note: attrs)
  def delete_note(id)                    = delete("/api/v1/notes/#{id}")
  def note_backlinks(id)                  = get("/api/v1/notes/#{id}/backlinks")
  def restore_note(id)                   = post("/api/v1/notes/#{id}/restore", {})
  def duplicate_note(id)                 = post("/api/v1/notes/#{id}/duplicate", {})
  def move_note(id, notebook_id)         = post("/api/v1/notes/#{id}/move", notebook_id: notebook_id)
  def share_note(id, expires_in: nil)     = post("/api/v1/notes/#{id}/share", expires_in ? { expires_in: expires_in } : {})
  def similar_notes(id)                  = get("/api/v1/notes/#{id}/similar")
  def unshare_note(id)                   = unshare("/api/v1/notes/#{id}/share")
  def pin_note(id)                       = post("/api/v1/notes/#{id}/pin", {})
  def unpin_note(id)                     = post("/api/v1/notes/#{id}/unpin", {})
  def favorite_note(id)                  = post("/api/v1/notes/#{id}/favorite", {})
  def unfavorite_note(id)                = post("/api/v1/notes/#{id}/unfavorite", {})

  # Bulk operations

  def bulk_tag_notes(note_ids, tag_ids)
    post("/api/v1/notes/bulk_tag", note_ids: note_ids, tag_ids: tag_ids)
  end

  def bulk_move_notes(note_ids, notebook_id)
    post("/api/v1/notes/bulk_move", note_ids: note_ids, notebook_id: notebook_id)
  end

  def bulk_delete_notes(note_ids)
    post("/api/v1/notes/bulk_delete", note_ids: note_ids)
  end

  def bulk_favorite_notes(note_ids, favorited)
    post("/api/v1/notes/bulk_favorite", note_ids: note_ids, favorited: favorited)
  end

  def bulk_pin_notes(note_ids, pinned)
    post("/api/v1/notes/bulk_pin", note_ids: note_ids, pinned: pinned)
  end

  # Versions

  def note_versions(note_id)             = get("/api/v1/notes/#{note_id}/versions")
  def note_version(note_id, version_id)  = get("/api/v1/notes/#{note_id}/versions/#{version_id}")
  def revert_note(note_id, version_id)   = post("/api/v1/notes/#{note_id}/versions/#{version_id}/revert", {})

  # Export

  def export_note_markdown(id)           = get_raw("/api/v1/export/#{id}/markdown")
  def export_note_html(id)               = get_raw("/api/v1/export/#{id}/html")
  def export_note_json(id)               = get_raw("/api/v1/export/#{id}/json")

  # Tags

  def tags                               = get("/api/v1/tags")
  def tag(id)                            = get("/api/v1/tags/#{id}")
  def create_tag(attrs)                  = post("/api/v1/tags", tag: attrs)
  def update_tag(id, attrs)              = patch("/api/v1/tags/#{id}", tag: attrs)
  def delete_tag(id)                     = delete("/api/v1/tags/#{id}")

  # Shared notes (public, no auth)

  def shared_note(shared_token)
    uri = URI("#{BASE_URL}/api/v1/shared/#{shared_token}")
    request = Net::HTTP::Get.new(uri)
    request["Accept"] = "application/json"
    self.class.execute(uri, request)
  end

  # Search

  def search(params)                     = get("/api/v1/search", params)
  def search_notes(params)               = get("/api/v1/notes/search", params)

  # Reminders

  def reminders(params = {})             = get("/api/v1/reminders", params)
  def reminders_due_today                = get("/api/v1/reminders/due_today")
  def create_reminder(attrs)             = post("/api/v1/reminders", reminder: attrs)
  def update_reminder(id, attrs)         = patch("/api/v1/reminders/#{id}", reminder: attrs)
  def delete_reminder(id)                = delete("/api/v1/reminders/#{id}")

  # Stats

  def stats                              = get("/api/v1/stats")
  def activity_stats                     = get("/api/v1/stats/activity")
  def stats_by_notebook                  = get("/api/v1/stats/by_notebook")
  def stats_by_tag                       = get("/api/v1/stats/by_tag")

  # Trash

  def trash(params = {})                 = get("/api/v1/trash", params)
  def empty_trash                        = delete("/api/v1/trash")

  # Note Templates

  def note_templates                     = get("/api/v1/note_templates")
  def note_template(id)                  = get("/api/v1/note_templates/#{id}")
  def create_template(attrs)             = post("/api/v1/note_templates", note_template: attrs)
  def update_template(id, attrs)         = patch("/api/v1/note_templates/#{id}", note_template: attrs)
  def delete_template(id)                = delete("/api/v1/note_templates/#{id}")
  def apply_template(id, notebook_id)    = post("/api/v1/note_templates/#{id}/apply", notebook_id: notebook_id)

  private

  def get(path, params = {})
    uri = URI("#{BASE_URL}#{path}")
    uri.query = URI.encode_www_form(params) if params.any?
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{@token}"
    request["Accept"] = "application/json"
    perform(uri, request)
  end

  def get_raw(path, params = {})
    uri = URI("#{BASE_URL}#{path}")
    uri.query = URI.encode_www_form(params) if params.any?
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{@token}"
    response = self.class.connection.request(request)
    response.body
  end

  def post(path, body)
    uri = URI("#{BASE_URL}#{path}")
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{@token}"
    request["Content-Type"] = "application/json"
    request.body = body.to_json
    perform(uri, request)
  end

  def patch(path, body)
    uri = URI("#{BASE_URL}#{path}")
    request = Net::HTTP::Patch.new(uri)
    request["Authorization"] = "Bearer #{@token}"
    request["Content-Type"] = "application/json"
    request.body = body.to_json
    perform(uri, request)
  end

  def delete(path)
    uri = URI("#{BASE_URL}#{path}")
    request = Net::HTTP::Delete.new(uri)
    request["Authorization"] = "Bearer #{@token}"
    perform(uri, request)
  end

  def unshare(path)
    uri = URI("#{BASE_URL}#{path}")
    request = Net::HTTP::Delete.new(uri)
    request["Authorization"] = "Bearer #{@token}"
    perform(uri, request)
  end

  def perform(uri, request)
    self.class.execute(uri, request)
  rescue IOError, Errno::EPIPE
    self.class.execute(uri, request)  # retry once with fresh connection
  end

  def self.connection
    Thread.current[:notes_api_http] ||= begin
      uri = URI(BASE_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 5
      http.read_timeout = 10
      http.keep_alive_timeout = 30
      http.start
      http
    end
  end

  def self.execute(uri, request)
    response = connection.request(request)
    parse_response(response)
  rescue IOError, Errno::EPIPE
    Thread.current[:notes_api_http] = nil
    raise
  rescue Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout
    Thread.current[:notes_api_http] = nil
    { "error" => "connection_failed", "message" => "Notes API is not reachable" }
  end

  def self.parse_response(response)
    case response
    when Net::HTTPNoContent
      { "success" => true }
    when Net::HTTPSuccess
      JSON.parse(response.body)
    else
      body = begin JSON.parse(response.body) rescue response.body end
      { "error" => response.code, "message" => body }
    end
  end
end

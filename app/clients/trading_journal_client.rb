require "net/http"

class TradingJournalClient
  BASE_URL = ENV.fetch("TRADING_JOURNAL_URL", "http://localhost:3001")

  def initialize(token)
    @token = token
  end

  # Auth

  def self.authenticate(login:, password:)
    uri = URI("#{BASE_URL}/api/v1/auth/token")
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = { login: login, password: password }.to_json
    execute(uri, request)
  end

  # Trades

  def trades(params = {})       = get("/api/v1/trades", params)
  def trade(id)                  = get("/api/v1/trades/#{id}")
  def create_trade(attrs)        = post("/api/v1/trades", trade: attrs)
  def update_trade(id, attrs)    = patch("/api/v1/trades/#{id}", trade: attrs)
  def delete_trade(id)           = delete("/api/v1/trades/#{id}")

  # Journal Entries

  def journal_entries(params = {})       = get("/api/v1/journal_entries", params)
  def journal_entry(id)                  = get("/api/v1/journal_entries/#{id}")
  def create_journal_entry(attrs)        = post("/api/v1/journal_entries", journal_entry: attrs)
  def update_journal_entry(id, attrs)    = patch("/api/v1/journal_entries/#{id}", journal_entry: attrs)
  def delete_journal_entry(id)           = delete("/api/v1/journal_entries/#{id}")

  # Tags

  def tags              = get("/api/v1/tags")
  def tag(id)           = get("/api/v1/tags/#{id}")
  def create_tag(attrs) = post("/api/v1/tags", tag: attrs)
  def update_tag(id, attrs) = patch("/api/v1/tags/#{id}", tag: attrs)
  def delete_tag(id)    = delete("/api/v1/tags/#{id}")

  # Trade Plans

  def trade_plans(params = {})         = get("/api/v1/trade_plans", params)
  def trade_plan(id)                   = get("/api/v1/trade_plans/#{id}")
  def create_trade_plan(attrs)         = post("/api/v1/trade_plans", trade_plan: attrs)
  def update_trade_plan(id, attrs)     = patch("/api/v1/trade_plans/#{id}", trade_plan: attrs)
  def delete_trade_plan(id)            = delete("/api/v1/trade_plans/#{id}")
  def execute_trade_plan(id, attrs = {}) = post("/api/v1/trade_plans/#{id}/execute", attrs)

  # Watchlists

  def watchlists(params = {})          = get("/api/v1/watchlists", params)
  def watchlist(id)                    = get("/api/v1/watchlists/#{id}")
  def create_watchlist(attrs)          = post("/api/v1/watchlists", watchlist: attrs)
  def update_watchlist(id, attrs)      = patch("/api/v1/watchlists/#{id}", watchlist: attrs)
  def delete_watchlist(id)             = delete("/api/v1/watchlists/#{id}")

  # Position Calculator

  def calculate_position(attrs)        = post("/api/v1/position_calculator/calculate", attrs)

  # Import / Export

  def import_trades(csv_content)
    post_csv("/api/v1/trades/import", csv_content)
  end

  def export_trades(params = {})       = get_raw("/api/v1/trades/export", params)

  # Comparison

  def compare_trades(trade_ids)    = get("/api/v1/comparison", trade_ids: trade_ids)

  # Reports

  def overview(params = {})        = get("/api/v1/reports/overview", params)
  def report_by_symbol(params = {}) = get("/api/v1/reports/by_symbol", params)
  def report_by_tag(params = {})   = get("/api/v1/reports/by_tag", params)
  def streaks(params = {})         = get("/api/v1/reports/streaks", params)
  def equity_curve(params = {})    = get("/api/v1/reports/equity_curve", params)
  def risk_analysis(params = {})   = get("/api/v1/reports/risk_analysis", params)
  def by_time(params = {})         = get("/api/v1/reports/by_time", params)
  def by_duration(params = {})     = get("/api/v1/reports/by_duration", params)
  def monte_carlo(params = {})     = get("/api/v1/reports/monte_carlo", params)
  def distribution(params = {})    = get("/api/v1/reports/distribution", params)
  def api_weekly_summary(params = {}) = get("/api/v1/reports/weekly_summary", params)
  def api_monthly_summary(params = {}) = get("/api/v1/reports/monthly_summary", params)
  def api_setup_analysis(params = {}) = get("/api/v1/reports/setup_analysis", params)
  def api_correlation(params = {}) = get("/api/v1/reports/correlation", params)
  def mood_analytics(params = {}) = get("/api/v1/reports/mood_analytics", params)

  # Trade Review
  def review_trade(id, attrs)      = post("/api/v1/trades/#{id}/review", attrs)
  def review_queue                 = get("/api/v1/trades/review_queue")
  def review_stats                 = get("/api/v1/trades/review_stats")

  # Playbooks

  def playbooks(params = {})          = get("/api/v1/playbooks", params)
  def playbook(id)                    = get("/api/v1/playbooks/#{id}")
  def create_playbook(attrs)          = post("/api/v1/playbooks", playbook: attrs)
  def update_playbook(id, attrs)      = patch("/api/v1/playbooks/#{id}", playbook: attrs)
  def delete_playbook(id)             = delete("/api/v1/playbooks/#{id}")

  # Screenshots

  def trade_screenshots(trade_id)          = get("/api/v1/trades/#{trade_id}/trade_screenshots")
  def create_screenshot(trade_id, attrs)   = post("/api/v1/trades/#{trade_id}/trade_screenshots", trade_screenshot: attrs)
  def delete_screenshot(trade_id, id)      = delete("/api/v1/trades/#{trade_id}/trade_screenshots/#{id}")

  # Bulk operations

  def bulk_update_trades(trade_ids, attrs) = post("/api/v1/trades/bulk_update", { trade_ids: trade_ids, trade: attrs })
  def bulk_delete_trades(trade_ids)        = post("/api/v1/trades/bulk_delete", { trade_ids: trade_ids })

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

  def post_csv(path, csv_content)
    uri = URI("#{BASE_URL}#{path}")
    boundary = "----FormBoundary#{SecureRandom.hex(8)}"
    body = ""
    body << "--#{boundary}\r\n"
    body << "Content-Disposition: form-data; name=\"file\"; filename=\"import.csv\"\r\n"
    body << "Content-Type: text/csv\r\n\r\n"
    body << csv_content
    body << "\r\n--#{boundary}--\r\n"

    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{@token}"
    request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
    request.body = body
    perform(uri, request)
  end

  def perform(uri, request)
    self.class.execute(uri, request)
  rescue IOError, Errno::EPIPE
    self.class.execute(uri, request)  # retry once with fresh connection
  end

  def self.connection
    Thread.current[:trading_journal_http] ||= begin
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
    Thread.current[:trading_journal_http] = nil
    raise
  rescue Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout
    Thread.current[:trading_journal_http] = nil
    { "error" => "connection_failed", "message" => "Trading Journal is not reachable" }
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

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

  # Reports

  def overview(params = {})        = get("/api/v1/reports/overview", params)
  def report_by_symbol(params = {}) = get("/api/v1/reports/by_symbol", params)
  def equity_curve(params = {})    = get("/api/v1/reports/equity_curve", params)

  private

  def get(path, params = {})
    uri = URI("#{BASE_URL}#{path}")
    uri.query = URI.encode_www_form(params) if params.any?
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{@token}"
    request["Accept"] = "application/json"
    perform(uri, request)
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

  def perform(uri, request)
    self.class.execute(uri, request)
  end

  def self.execute(uri, request)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    response = http.request(request)
    parse_response(response)
  rescue Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout
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

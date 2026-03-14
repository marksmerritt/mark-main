class TradingJournalClient
  BASE_URL = ENV.fetch("TRADING_JOURNAL_URL", "http://localhost:3001")

  def initialize(token)
    @token = token
  end

  # Auth

  def self.authenticate(login:, password:)
    response = post_unauthenticated("/api/v1/auth/token", { login: login, password: password })
    response
  end

  # Trades

  def trades(params = {})
    get("/api/v1/trades", params)
  end

  def trade(id)
    get("/api/v1/trades/#{id}")
  end

  def create_trade(attrs)
    post("/api/v1/trades", { trade: attrs })
  end

  def update_trade(id, attrs)
    patch("/api/v1/trades/#{id}", { trade: attrs })
  end

  def delete_trade(id)
    delete("/api/v1/trades/#{id}")
  end

  # Journal Entries

  def journal_entries(params = {})
    get("/api/v1/journal_entries", params)
  end

  def journal_entry(id)
    get("/api/v1/journal_entries/#{id}")
  end

  def create_journal_entry(attrs)
    post("/api/v1/journal_entries", { journal_entry: attrs })
  end

  def update_journal_entry(id, attrs)
    patch("/api/v1/journal_entries/#{id}", { journal_entry: attrs })
  end

  def delete_journal_entry(id)
    delete("/api/v1/journal_entries/#{id}")
  end

  # Tags

  def tags
    get("/api/v1/tags")
  end

  def tag(id)
    get("/api/v1/tags/#{id}")
  end

  def create_tag(attrs)
    post("/api/v1/tags", { tag: attrs })
  end

  def update_tag(id, attrs)
    patch("/api/v1/tags/#{id}", { tag: attrs })
  end

  def delete_tag(id)
    delete("/api/v1/tags/#{id}")
  end

  # Reports

  def overview(params = {})
    get("/api/v1/reports/overview", params)
  end

  def report_by_symbol(params = {})
    get("/api/v1/reports/by_symbol", params)
  end

  def equity_curve(params = {})
    get("/api/v1/reports/equity_curve", params)
  end

  private

  def get(path, params = {})
    uri = URI("#{BASE_URL}#{path}")
    uri.query = URI.encode_www_form(params) if params.any?
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{@token}"
    request["Accept"] = "application/json"
    execute(uri, request)
  end

  def post(path, body)
    uri = URI("#{BASE_URL}#{path}")
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{@token}"
    request["Content-Type"] = "application/json"
    request.body = body.to_json
    execute(uri, request)
  end

  def patch(path, body)
    uri = URI("#{BASE_URL}#{path}")
    request = Net::HTTP::Patch.new(uri)
    request["Authorization"] = "Bearer #{@token}"
    request["Content-Type"] = "application/json"
    request.body = body.to_json
    execute(uri, request)
  end

  def delete(path)
    uri = URI("#{BASE_URL}#{path}")
    request = Net::HTTP::Delete.new(uri)
    request["Authorization"] = "Bearer #{@token}"
    execute(uri, request)
  end

  def self.post_unauthenticated(path, body)
    uri = URI("#{BASE_URL}#{path}")
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = body.to_json
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    response = http.request(request)
    parse_response(response)
  end

  def execute(uri, request)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    response = http.request(request)
    self.class.parse_response(response)
  end

  def self.parse_response(response)
    case response
    when Net::HTTPNoContent
      { success: true }
    when Net::HTTPSuccess
      JSON.parse(response.body)
    else
      { error: response.code, message: JSON.parse(response.body) rescue response.body }
    end
  end
end

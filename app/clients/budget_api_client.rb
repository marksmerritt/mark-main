require "net/http"

class BudgetApiClient
  BASE_URL = ENV.fetch("BUDGET_API_URL", "http://localhost:3003")

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

  # Budgets

  def budgets(params = {})                 = get("/api/v1/budgets", params)
  def budget(id)                           = get("/api/v1/budgets/#{id}")
  def current_budget                       = get("/api/v1/budgets/current")
  def create_budget(attrs)                 = post("/api/v1/budgets", budget: attrs)
  def create_budget_from_template(attrs, template: "ramsey") = post("/api/v1/budgets", budget: attrs, from_template: true, template: template)
  def budget_templates                     = get("/api/v1/budgets/templates")
  def update_budget(id, attrs)             = patch("/api/v1/budgets/#{id}", budget: attrs)
  def delete_budget(id)                    = delete("/api/v1/budgets/#{id}")
  def copy_budget(id, month, year)         = post("/api/v1/budgets/#{id}/copy", target_month: month, target_year: year)
  def rollover_budget(id, month, year)     = post("/api/v1/budgets/#{id}/rollover", target_month: month, target_year: year)
  def rollover_preview(id)                 = get("/api/v1/budgets/#{id}/rollover_preview")

  # Budget Categories

  def budget_categories(budget_id)                    = get("/api/v1/budgets/#{budget_id}/budget_categories")
  def budget_category(budget_id, id)                  = get("/api/v1/budgets/#{budget_id}/budget_categories/#{id}")
  def create_budget_category(budget_id, attrs)        = post("/api/v1/budgets/#{budget_id}/budget_categories", budget_category: attrs)
  def update_budget_category(budget_id, id, attrs)    = patch("/api/v1/budgets/#{budget_id}/budget_categories/#{id}", budget_category: attrs)
  def delete_budget_category(budget_id, id)           = delete("/api/v1/budgets/#{budget_id}/budget_categories/#{id}")

  # Budget Items

  def budget_items(budget_id, category_id)                 = get("/api/v1/budgets/#{budget_id}/budget_categories/#{category_id}/budget_items")
  def create_budget_item(budget_id, category_id, attrs)    = post("/api/v1/budgets/#{budget_id}/budget_categories/#{category_id}/budget_items", budget_item: attrs)
  def update_budget_item(budget_id, category_id, id, attrs) = patch("/api/v1/budgets/#{budget_id}/budget_categories/#{category_id}/budget_items/#{id}", budget_item: attrs)
  def delete_budget_item(budget_id, category_id, id)       = delete("/api/v1/budgets/#{budget_id}/budget_categories/#{category_id}/budget_items/#{id}")

  # Transactions

  def transactions(params = {})            = get("/api/v1/transactions", params)
  def transaction(id)                      = get("/api/v1/transactions/#{id}")
  def create_transaction(attrs)            = post("/api/v1/transactions", transaction: attrs)
  def update_transaction(id, attrs)        = patch("/api/v1/transactions/#{id}", transaction: attrs)
  def delete_transaction(id)               = delete("/api/v1/transactions/#{id}")
  def assign_transaction(id, item_id)      = patch("/api/v1/transactions/#{id}/assign", budget_item_id: item_id)
  def split_transaction(id, splits)        = post("/api/v1/transactions/#{id}/split", splits: splits)
  def unsplit_transaction(id)              = post("/api/v1/transactions/#{id}/unsplit", {})
  def bulk_assign_transactions(ids, item_id) = post("/api/v1/transactions/bulk_assign", transaction_ids: ids, budget_item_id: item_id)
  def bulk_delete_transactions(ids)          = post("/api/v1/transactions/bulk_delete", transaction_ids: ids)
  def merchant_autocomplete(query)          = get("/api/v1/transactions/merchants", q: query)
  def export_transactions(params = {})     = get_raw("/api/v1/transactions/export", params)
  def import_transactions(csv_data)        = post_raw("/api/v1/transactions/import", csv_data, "text/csv")

  # Funds

  def funds(params = {})                   = get("/api/v1/funds", params)
  def fund(id)                             = get("/api/v1/funds/#{id}")
  def create_fund(attrs)                   = post("/api/v1/funds", fund: attrs)
  def update_fund(id, attrs)               = patch("/api/v1/funds/#{id}", fund: attrs)
  def delete_fund(id)                      = delete("/api/v1/funds/#{id}")
  def contribute_to_fund(id, amount, note: nil) = post("/api/v1/funds/#{id}/contribute", amount: amount, note: note)

  # Debt Accounts

  def debt_accounts(params = {})           = get("/api/v1/debt_accounts", params)
  def debt_account(id)                     = get("/api/v1/debt_accounts/#{id}")
  def create_debt_account(attrs)           = post("/api/v1/debt_accounts", debt_account: attrs)
  def update_debt_account(id, attrs)       = patch("/api/v1/debt_accounts/#{id}", debt_account: attrs)
  def delete_debt_account(id)              = delete("/api/v1/debt_accounts/#{id}")
  def pay_debt(id, amount, note: nil, payment_type: "regular") = post("/api/v1/debt_accounts/#{id}/pay", amount: amount, note: note, payment_type: payment_type)
  def snowball_plan(extra: 0)              = get("/api/v1/debt_accounts/snowball_plan", extra_payment: extra)
  def avalanche_plan(extra: 0)             = get("/api/v1/debt_accounts/avalanche_plan", extra_payment: extra)

  # Goals

  def goals(status: nil, goal_type: nil)
    params = {}
    params[:status] = status if status
    params[:goal_type] = goal_type if goal_type
    get("/api/v1/goals", params)
  end
  def goal(id)                             = get("/api/v1/goals/#{id}")
  def create_goal(attrs)                   = post("/api/v1/goals", goal: attrs)
  def update_goal(id, attrs)               = patch("/api/v1/goals/#{id}", goal: attrs)
  def delete_goal(id)                      = delete("/api/v1/goals/#{id}")
  def update_goal_progress(id, amount)     = post("/api/v1/goals/#{id}/update_progress", current_amount: amount)
  def sync_goal(id)                        = post("/api/v1/goals/#{id}/sync", {})

  # Recurring Transactions

  # Tags
  def tags                                 = get("/api/v1/tags")
  def tag(id)                              = get("/api/v1/tags/#{id}")
  def create_tag(attrs)                    = post("/api/v1/tags", tag: attrs)
  def update_tag(id, attrs)               = patch("/api/v1/tags/#{id}", tag: attrs)
  def delete_tag(id)                       = delete("/api/v1/tags/#{id}")
  def add_tag_to_transaction(txn_id, tag_name, color: nil)
    body = { tag_name: tag_name }
    body[:color] = color if color
    post("/api/v1/transactions/#{txn_id}/add_tag", body)
  end
  def remove_tag_from_transaction(txn_id, tag_name) = delete_with_body("/api/v1/transactions/#{txn_id}/remove_tag", tag_name: tag_name)

  # Spending Rules
  def spending_rules(params = {})         = get("/api/v1/spending_rules", params)
  def spending_rule(id)                   = get("/api/v1/spending_rules/#{id}")
  def create_spending_rule(attrs)         = post("/api/v1/spending_rules", spending_rule: attrs)
  def update_spending_rule(id, attrs)     = patch("/api/v1/spending_rules/#{id}", spending_rule: attrs)
  def delete_spending_rule(id)            = delete("/api/v1/spending_rules/#{id}")
  def evaluate_spending_rules             = get("/api/v1/spending_rules/evaluate")

  # Savings Challenges
  def savings_challenges(params = {})      = get("/api/v1/savings_challenges", params)
  def savings_challenge(id)               = get("/api/v1/savings_challenges/#{id}")
  def create_savings_challenge(attrs)     = post("/api/v1/savings_challenges", savings_challenge: attrs)
  def create_challenge_from_preset(preset, start_date: nil)
    body = { preset: preset }
    body[:start_date] = start_date if start_date
    post("/api/v1/savings_challenges", body)
  end
  def update_savings_challenge(id, attrs) = patch("/api/v1/savings_challenges/#{id}", savings_challenge: attrs)
  def delete_savings_challenge(id)        = delete("/api/v1/savings_challenges/#{id}")
  def evaluate_challenge(id)              = post("/api/v1/savings_challenges/#{id}/evaluate", {})
  def abandon_challenge(id)               = post("/api/v1/savings_challenges/#{id}/abandon", {})
  def challenge_presets                    = get("/api/v1/savings_challenges/presets")

  # Net Worth Snapshots
  def net_worth_snapshots(params = {})    = get("/api/v1/net_worth_snapshots", params)
  def take_net_worth_snapshot             = post("/api/v1/net_worth_snapshots", {})
  def net_worth_timeline                  = get("/api/v1/net_worth_snapshots/timeline")

  def recurring_transactions(params = {})  = get("/api/v1/recurring_transactions", params)
  def recurring_transaction(id)            = get("/api/v1/recurring_transactions/#{id}")
  def create_recurring_transaction(attrs)  = post("/api/v1/recurring_transactions", recurring_transaction: attrs)
  def update_recurring_transaction(id, attrs) = patch("/api/v1/recurring_transactions/#{id}", recurring_transaction: attrs)
  def delete_recurring_transaction(id)     = delete("/api/v1/recurring_transactions/#{id}")
  def skip_recurring(id)                   = post("/api/v1/recurring_transactions/#{id}/skip", {})
  def recurring_summary                    = get("/api/v1/recurring_transactions/summary")
  def auto_process_recurring               = post("/api/v1/recurring_transactions/auto_process", {})

  # Reports

  def budget_overview(params = {})         = get("/api/v1/reports/overview", params)
  def spending_by_category(params = {})    = get("/api/v1/reports/spending_by_category", params)
  def spending_trends(params = {})         = get("/api/v1/reports/spending_trends", params)
  def cash_flow(params = {})               = get("/api/v1/reports/cash_flow", params)
  def debt_overview                        = get("/api/v1/reports/debt_overview")
  def net_worth                            = get("/api/v1/reports/net_worth")
  def income_vs_expenses(params = {})      = get("/api/v1/reports/income_vs_expenses", params)
  def budget_comparison(params = {})       = get("/api/v1/reports/budget_comparison", params)
  def merchant_insights(params = {})      = get("/api/v1/reports/merchant_insights", params)
  def forecast(params = {})               = get("/api/v1/reports/forecast", params)
  def spending_insights(params = {})      = get("/api/v1/reports/spending_insights", params)
  def year_over_year(params = {})         = get("/api/v1/reports/year_over_year", params)

  # Alerts

  def alerts(params = {})                 = get("/api/v1/alerts", params)
  def generate_alerts                     = post("/api/v1/alerts/generate", {})
  def mark_alert_read(id)                 = post("/api/v1/alerts/#{id}/mark_read", {})
  def mark_all_alerts_read                = post("/api/v1/alerts/mark_read", {})
  def acknowledge_alert(id)               = post("/api/v1/alerts/#{id}/acknowledge", {})
  def delete_alert(id)                    = delete("/api/v1/alerts/#{id}")
  def clear_read_alerts                   = delete("/api/v1/alerts/clear")

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

  def delete_with_body(path, body)
    uri = URI("#{BASE_URL}#{path}")
    request = Net::HTTP::Delete.new(uri)
    request["Authorization"] = "Bearer #{@token}"
    request["Content-Type"] = "application/json"
    request.body = body.to_json
    perform(uri, request)
  end

  def get_raw(path, params = {})
    uri = URI("#{BASE_URL}#{path}")
    uri.query = URI.encode_www_form(params) if params.any?
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{@token}"
    perform_raw(uri, request)
  end

  def post_raw(path, body, content_type)
    uri = URI("#{BASE_URL}#{path}")
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{@token}"
    request["Content-Type"] = content_type
    request.body = body
    perform(uri, request)
  end

  def perform(uri, request)
    self.class.execute(uri, request)
  rescue IOError, Errno::EPIPE
    self.class.execute(uri, request)
  end

  def perform_raw(uri, request)
    self.class.execute_raw(uri, request)
  rescue IOError, Errno::EPIPE
    self.class.execute_raw(uri, request)
  end

  def self.connection
    Thread.current[:budget_api_http] ||= begin
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
    Thread.current[:budget_api_http] = nil
    raise
  rescue Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout
    Thread.current[:budget_api_http] = nil
    { "error" => "connection_failed", "message" => "Budget API is not reachable" }
  end

  def self.execute_raw(uri, request)
    response = connection.request(request)
    response.body
  rescue IOError, Errno::EPIPE
    Thread.current[:budget_api_http] = nil
    raise
  rescue Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout
    Thread.current[:budget_api_http] = nil
    nil
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

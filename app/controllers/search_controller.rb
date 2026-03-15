class SearchController < ApplicationController
  def index
    @query = params[:q]
    @trades = []
    @notes = []
    @journal_entries = []
    @errors = []

    return unless @query.present?

    threads = {}

    threads[:trades] = Thread.new do
      next [] unless api_token.present?
      result = api_client.trades(q: @query, per_page: 20)
      if result.is_a?(Hash) && result["error"]
        @errors << "Trading Journal: #{result["message"]}"
        []
      else
        result.is_a?(Hash) ? (result["trades"] || []) : Array(result)
      end
    end

    threads[:journal] = Thread.new do
      next [] unless api_token.present?
      result = api_client.journal_entries(q: @query)
      if result.is_a?(Hash) && result["error"]
        []
      else
        result.is_a?(Array) ? result : (result.is_a?(Hash) ? (result["journal_entries"] || []) : [])
      end
    end

    threads[:notes] = Thread.new do
      next [] unless notes_api_token.present?
      result = notes_client.search(q: @query)
      if result.is_a?(Hash) && result["error"]
        @errors << "Notes API: #{result["message"]}"
        []
      else
        result.is_a?(Hash) ? (result["notes"] || []) : Array(result)
      end
    end

    threads[:transactions] = Thread.new do
      next [] unless budget_api_token.present?
      result = budget_client.transactions(merchant: @query, start_date: 1.year.ago.to_date.to_s, end_date: Date.current.to_s)
      txns = result.is_a?(Hash) ? (result["transactions"] || []) : Array(result)
      txns.is_a?(Array) ? txns.first(20) : []
    rescue
      []
    end

    @trades = threads[:trades].value
    @journal_entries = threads[:journal].value
    @notes = threads[:notes].value
    @transactions = threads[:transactions].value
    @total_results = @trades.count + @journal_entries.count + @notes.count + @transactions.count
  end
end

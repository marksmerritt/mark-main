class NoteTopicsController < ApplicationController
  before_action :require_notes_connection

  STOP_WORDS = %w[
    the a an is are was were be been being have has had do does did will would
    could should may might shall can and or but if then else when where which
    that this these those it its i me my we our us you your he him his
    she her they them their what who whom how why not no nor so too very just
    also about above after again all am any at before below between both by
    down during each few for from further get got had has here in into more
    most of off on once only other out over own same some such than to under
    until up while with there here been being does doing done from going goes
    gone having make made much many must need new now old only really still
    take through want well like even back one two three four five six seven
    eight nine ten first last long great little right big come end good high
    know let made part put say set try use way went work time people year
    day thing man world life hand place case week point keep eye next thought
    look find called left full along best upon early however hard stay name
    write read line close open turn move tell show help think see give run
    start begin seem talk sure feel every much used said also another still
  ].freeze

  def show
    notes_result = begin
      notes_client.notes(per_page: 1000)
    rescue => e
      Rails.logger.error("NoteTopics notes fetch error: #{e.message}")
      []
    end

    @notes = notes_result.is_a?(Hash) ? (notes_result["notes"] || []) : Array(notes_result)
    @notes = @notes.select { |n| n.is_a?(Hash) }

    notebooks_result = begin
      notes_client.notebooks
    rescue => e
      Rails.logger.error("NoteTopics notebooks fetch error: #{e.message}")
      []
    end
    @notebooks = notebooks_result.is_a?(Array) ? notebooks_result : (notebooks_result.is_a?(Hash) ? (notebooks_result["notebooks"] || []) : [])

    # Extract keywords from each note
    global_keyword_freq = Hash.new(0)
    keyword_by_month = Hash.new { |h, k| h[k] = Hash.new(0) }
    keyword_by_notebook = Hash.new { |h, k| h[k] = Hash.new(0) }
    note_keywords_map = {}

    @notes.each do |n|
      content = (n["content"] || n["body"] || "").to_s
      title = (n["title"] || "").to_s
      text = "#{title} #{content}".gsub(/<[^>]+>/, " ").gsub(/[#*_~`\[\]\(\)>]/, " ")
      words = text.downcase.scan(/[a-z']+/).select { |w| w.length >= 4 }
      keywords = words.reject { |w| STOP_WORDS.include?(w) }

      n["_created_date"] = Date.parse(n["created_at"] || n["updated_at"] || "") rescue nil
      n["_word_count"] = words.count

      # Per-note keyword frequency
      note_freq = Hash.new(0)
      keywords.each { |w| note_freq[w] += 1 }
      n["_keywords"] = note_freq
      note_keywords_map[n["id"]] = note_freq

      # Global frequency
      keywords.each { |w| global_keyword_freq[w] += 1 }

      # By month
      if n["_created_date"]
        month = n["_created_date"].strftime("%Y-%m")
        keywords.each { |w| keyword_by_month[month][w] += 1 }
      end

      # By notebook
      nb_name = n.dig("notebook", "name") || "No Notebook"
      keywords.each { |w| keyword_by_notebook[nb_name][w] += 1 }
    end

    # --- Theme extraction: top keywords across corpus ---
    sorted_keywords = global_keyword_freq.sort_by { |_, v| -v }
    @themes = sorted_keywords.first(10).map { |word, count| { name: word, count: count } }

    # --- Topic clustering: group notes by shared frequent keywords ---
    # Find top keywords (potential topic seeds)
    topic_seeds = sorted_keywords.first(30).map { |w, _| w }

    @topics = []
    used_seed_keywords = Set.new

    topic_seeds.each do |seed|
      next if used_seed_keywords.include?(seed)

      # Find notes containing this keyword
      matching_notes = @notes.select { |n| (n["_keywords"] || {})[seed].to_i > 0 }
      next if matching_notes.count < 2

      # Find co-occurring keywords across matching notes
      co_keywords = Hash.new(0)
      matching_notes.each do |n|
        (n["_keywords"] || {}).each do |kw, cnt|
          co_keywords[kw] += cnt if kw != seed && !STOP_WORDS.include?(kw)
        end
      end

      top_co = co_keywords.sort_by { |_, v| -v }.first(6).map { |w, _| w }
      topic_keywords = [seed] + top_co

      # Check shared keywords: notes that share 3+ of the topic keywords
      clustered_notes = matching_notes.select do |n|
        nk = (n["_keywords"] || {}).keys
        (nk & topic_keywords).count >= 3
      end
      # Fall back to all notes with the seed keyword if cluster is too small
      clustered_notes = matching_notes if clustered_notes.count < 2

      total_words = clustered_notes.sum { |n| n["_word_count"].to_i }
      dates = clustered_notes.map { |n| n["_created_date"] }.compact.sort
      first_seen = dates.first
      last_seen = dates.last

      # Trend: compare recent vs older activity
      trend = compute_trend(clustered_notes)

      @topics << {
        name: seed,
        keywords: topic_keywords.first(7),
        note_count: clustered_notes.count,
        total_words: total_words,
        first_seen: first_seen,
        last_seen: last_seen,
        trend: trend,
        note_ids: clustered_notes.map { |n| n["id"] }
      }

      used_seed_keywords.add(seed)
      top_co.first(2).each { |k| used_seed_keywords.add(k) }
    end

    @topics = @topics.sort_by { |t| -t[:note_count] }.first(15)

    # --- Stats ---
    @topics_found = @topics.count
    @top_topic = @topics.first
    @notes_covered = @topics.flat_map { |t| t[:note_ids] }.uniq.count
    @notes_covered_pct = @notes.count > 0 ? (@notes_covered.to_f / @notes.count * 100).round(1) : 0

    # --- Emerging topics (growing trend, recent last_seen) ---
    @emerging_topics = @topics.select { |t| t[:trend] == "growing" }.sort_by { |t| -(t[:last_seen] || Date.new(2000)).to_time.to_i }.first(5)

    # --- Fading topics (fading trend) ---
    @fading_topics = @topics.select { |t| t[:trend] == "fading" }.sort_by { |t| -t[:note_count] }.first(5)

    # --- Topic timeline: monthly activity for top topics ---
    @topic_timeline = {}
    @topics.first(8).each do |topic|
      monthly = Hash.new(0)
      @notes.each do |n|
        next unless n["_created_date"]
        nk = (n["_keywords"] || {}).keys
        if nk.include?(topic[:name])
          month = n["_created_date"].strftime("%Y-%m")
          monthly[month] += 1
        end
      end
      @topic_timeline[topic[:name]] = monthly
    end
    @all_months = keyword_by_month.keys.sort
    @all_months = @all_months.last(12) if @all_months.count > 12

    # --- Cross-notebook topics: topics found in 2+ notebooks ---
    @cross_notebook_topics = []
    @topics.each do |topic|
      notebooks_with_topic = Set.new
      @notes.each do |n|
        if (n["_keywords"] || {}).key?(topic[:name])
          nb = n.dig("notebook", "name") || "No Notebook"
          notebooks_with_topic.add(nb)
        end
      end
      if notebooks_with_topic.count >= 2
        @cross_notebook_topics << {
          name: topic[:name],
          notebooks: notebooks_with_topic.to_a,
          notebook_count: notebooks_with_topic.count,
          note_count: topic[:note_count]
        }
      end
    end
    @cross_notebook_topics = @cross_notebook_topics.sort_by { |t| -t[:notebook_count] }

    # --- Topic diversity score ---
    @unique_topic_keywords = @topics.flat_map { |t| t[:keywords] }.uniq.count
    @topic_diversity = if @notes.count > 0 && @topics.any?
      # Ratio: unique topics relative to notes
      score = (@topics.count.to_f / [@notes.count, 1].max * 100).round(1)
      [score, 100].min
    else
      0
    end
    @diversity_label = case @topic_diversity
    when 0..2 then "Very Focused"
    when 2..5 then "Focused"
    when 5..10 then "Moderate"
    when 10..20 then "Diverse"
    else "Very Diverse"
    end

    # --- Topic depth (already in topics) ---
    @topic_depth = @topics.map { |t| { name: t[:name], notes: t[:note_count], words: t[:total_words] } }

  rescue => e
    Rails.logger.error("NoteTopics error: #{e.message}")
    @notes = []
    @topics = []
    @themes = []
    @topics_found = 0
    @top_topic = nil
    @emerging_topics = []
    @fading_topics = []
    @notes_covered = 0
    @notes_covered_pct = 0
    @topic_timeline = {}
    @all_months = []
    @cross_notebook_topics = []
    @unique_topic_keywords = 0
    @topic_diversity = 0
    @diversity_label = "N/A"
    @topic_depth = []
    @error = e.message
  end

  private

  def compute_trend(notes)
    dated = notes.select { |n| n["_created_date"] }.sort_by { |n| n["_created_date"] }
    return "stable" if dated.count < 2

    mid = dated.count / 2
    older = dated[0...mid]
    newer = dated[mid..]

    return "stable" if older.empty? || newer.empty?

    older_span = ((older.last["_created_date"] - older.first["_created_date"]).to_f + 1).abs
    newer_span = ((newer.last["_created_date"] - newer.first["_created_date"]).to_f + 1).abs

    older_rate = older.count / [older_span, 1].max
    newer_rate = newer.count / [newer_span, 1].max

    if newer_rate > older_rate * 1.3
      "growing"
    elsif newer_rate < older_rate * 0.7
      "fading"
    else
      "stable"
    end
  end
end

class NoteLinksController < ApplicationController
  before_action :require_notes_connection

  STOP_WORDS = Set.new(%w[
    the a an and or but in on at to for of is it this that was were be been
    being have has had do does did will would shall should may might can could
    with from by as are am not no nor so if then than too very just about
    above after again all also any because before between both each few how
    into more most other out over own same some such up down off once only
    our own its my your his her we they them their what which who whom
    where when why these those there here through during under until while
  ]).freeze

  def show
    result = notes_client.notes(per_page: 1000)
    all_notes = result.is_a?(Hash) ? (result["notes"] || []) : Array(result)
    @notes = all_notes.select { |n| n.is_a?(Hash) }

    analyze_connections
  end

  private

  def analyze_connections
    # -- Shared Tags --
    @tag_groups = {}
    @notes.each do |note|
      tags = note["tags"] || []
      tags.each do |tag|
        name = tag.is_a?(Hash) ? tag["name"] : tag.to_s
        next if name.blank?
        @tag_groups[name] ||= []
        @tag_groups[name] << note
      end
    end
    # Only keep tags shared by 2+ notes
    @tag_groups.select! { |_, notes| notes.length >= 2 }
    @tag_groups = @tag_groups.sort_by { |_, notes| -notes.length }.to_h

    # -- Tag Co-occurrence Matrix (top 10 tags) --
    top_tags = @tag_groups.keys.first(10)
    @tag_cooccurrence = {}
    top_tags.each do |tag_a|
      @tag_cooccurrence[tag_a] = {}
      ids_a = Set.new(@tag_groups[tag_a]&.map { |n| n["id"] })
      top_tags.each do |tag_b|
        ids_b = Set.new(@tag_groups[tag_b]&.map { |n| n["id"] })
        @tag_cooccurrence[tag_a][tag_b] = (ids_a & ids_b).size
      end
    end

    # -- Keyword Extraction --
    @note_keywords = {}
    @notes.each do |note|
      content = (note["content"] || note["body"] || "").to_s
      title = (note["title"] || "").to_s
      text = "#{title} #{content}"
      words = text.downcase.gsub(/[^a-z0-9\s]/, " ").split(/\s+/)
      words.reject! { |w| w.length < 3 || STOP_WORDS.include?(w) }
      freq = Hash.new(0)
      words.each { |w| freq[w] += 1 }
      @note_keywords[note["id"]] = freq.sort_by { |_, c| -c }.first(10).map(&:first)
    end

    # -- Keyword Overlap / Suggested Links --
    @suggested_links = []
    note_ids = @notes.map { |n| n["id"] }
    checked = Set.new
    @notes.each do |note_a|
      kw_a = Set.new(@note_keywords[note_a["id"]] || [])
      next if kw_a.empty?
      @notes.each do |note_b|
        next if note_a["id"] == note_b["id"]
        pair = [note_a["id"], note_b["id"]].sort
        next if checked.include?(pair)
        checked.add(pair)

        kw_b = Set.new(@note_keywords[note_b["id"]] || [])
        shared = kw_a & kw_b
        if shared.size >= 3
          @suggested_links << {
            note_a: note_a,
            note_b: note_b,
            shared_keywords: shared.to_a.first(5),
            score: shared.size
          }
        end
      end
    end
    @suggested_links.sort_by! { |l| -l[:score] }
    @suggested_links = @suggested_links.first(20)

    # -- Temporal Clusters (same day) --
    @temporal_clusters = {}
    @notes.each do |note|
      date = (note["created_at"] || note["updated_at"]).to_s.slice(0, 10)
      next if date.blank?
      @temporal_clusters[date] ||= []
      @temporal_clusters[date] << note
    end
    @temporal_clusters.select! { |_, notes| notes.length >= 2 }
    @temporal_clusters = @temporal_clusters.sort_by { |date, _| date }.reverse.first(15).to_h

    # -- Notebook Connections --
    @notebook_groups = {}
    @notes.each do |note|
      nb_name = note.dig("notebook", "name") || "No Notebook"
      @notebook_groups[nb_name] ||= []
      @notebook_groups[nb_name] << note
    end
    @notebook_groups = @notebook_groups.sort_by { |_, notes| -notes.length }.to_h

    # -- Adjacency List --
    @adjacency = Hash.new { |h, k| h[k] = Set.new }

    # Tag-based connections
    @tag_groups.each do |_tag, notes|
      ids = notes.map { |n| n["id"] }
      ids.combination(2).each do |a, b|
        @adjacency[a].add(b)
        @adjacency[b].add(a)
      end
    end

    # Keyword-based connections
    @suggested_links.each do |link|
      @adjacency[link[:note_a]["id"]].add(link[:note_b]["id"])
      @adjacency[link[:note_b]["id"]].add(link[:note_a]["id"])
    end

    # -- Connection counts --
    @connection_counts = {}
    @notes.each { |n| @connection_counts[n["id"]] = @adjacency[n["id"]].size }

    # -- Orphan Notes --
    @orphan_notes = @notes.select do |note|
      tags = note["tags"] || []
      has_tags = tags.any?
      has_notebook = note.dig("notebook", "name").present?
      has_connections = @adjacency[note["id"]].any?
      !has_tags && !has_notebook && !has_connections
    end

    # -- Hub Notes (top 10 by connection count) --
    @hub_notes = @notes
      .select { |n| @connection_counts[n["id"]].to_i > 0 }
      .sort_by { |n| -@connection_counts[n["id"]].to_i }
      .first(10)

    # -- Stats --
    @total_notes = @notes.count
    @connected_count = @notes.count { |n| @adjacency[n["id"]].any? }
    @orphan_count = @orphan_notes.count
    @tag_cluster_count = @tag_groups.count
    @hub_count = @hub_notes.count { |n| @connection_counts[n["id"]].to_i >= 3 }
  end
end

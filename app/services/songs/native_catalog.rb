module Songs
  class NativeCatalog
    CATALOG_PATH = Rails.root.join("config/catalog/native_songs.json").freeze

    def self.all
      @all ||= JSON.parse(File.read(CATALOG_PATH))
    end

    def self.fetch(slug)
      song = all[slug.to_s]
      song&.deep_dup
    end

    def self.slugs
      all.keys
    end

    def self.seed_all!
      all.each do |slug, payload|
        song = Song.find_or_initialize_by(slug: slug)
        song.assign_attributes(
          title: payload.dig("meta", "title"),
          artist: payload.dig("meta", "artist"),
          source_type: "native",
          status: "ready",
          key_signature: payload.dig("meta", "key"),
          default_bpm: payload.dig("meta", "defaultBpm"),
          time_signature: payload.dig("meta", "timeSignature"),
          total_measures: payload["steps"].size,
          payload: payload
        )
        song.save!
      end
    end
  end
end

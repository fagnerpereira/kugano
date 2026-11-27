class Song < ApplicationRecord
  SOURCE_TYPES = Songs::SchemaValidator::SOURCE_TYPES
  STATUSES = %w[processing ready failed].freeze

  has_one_attached :source_file

  validates :slug, presence: true, uniqueness: true, format: { with: Songs::SchemaValidator::SLUG_REGEX }
  validates :title, presence: true
  validates :source_type, inclusion: { in: SOURCE_TYPES }
  validates :status, inclusion: { in: STATUSES }
  validate :validate_song_schema_payload, if: :ready?

  scope :native, -> { where(source_type: "native") }
  scope :imported, -> { where.not(source_type: "native") }
  scope :ready, -> { where(status: "ready") }

  before_validation :sync_metadata_from_payload, if: -> { payload.is_a?(Hash) && payload["meta"].is_a?(Hash) }

  def ready?
    status == "ready"
  end

  def processing?
    status == "processing"
  end

  def failed?
    status == "failed"
  end

  private

  def sync_metadata_from_payload
    meta = payload["meta"]
    self.title = meta["title"] if meta["title"].present?
    self.artist = meta["artist"] if meta["artist"].present?
    self.key_signature = meta["key"] if meta["key"].present?
    self.default_bpm = meta["defaultBpm"] if meta["defaultBpm"].present?
    self.time_signature = meta["timeSignature"] if meta["timeSignature"].present?
    self.total_measures = Array(payload["steps"]).size if payload["steps"].is_a?(Array)
  end

  def validate_song_schema_payload
    result = Songs::SchemaValidator.validate(payload)
    return if result.valid?

    result.errors.each do |err|
      errors.add(:payload, err)
    end
  end
end

class Environment < ApplicationRecord
  KINDS = {
    production: "production",
    staging: "staging",
    custom: "custom"
  }.freeze

  belongs_to :project
  has_many :configuration_versions, dependent: :restrict_with_exception
  has_many :configuration_snapshots, dependent: :restrict_with_exception
  has_many :deployments, dependent: :restrict_with_exception

  delegate :organization, :organization_id, to: :project

  enum :kind, KINDS, prefix: true, validate: true
  enum :lifecycle_state, Project::LIFECYCLE_STATES, prefix: true, validate: true

  before_validation :normalize_attributes

  validates :name, presence: true, length: { maximum: 120 }
  validates :slug,
    presence: true,
    length: { maximum: 64 },
    format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/ },
    uniqueness: { scope: :project_id }
  validates :branch, length: { maximum: 255 }, uniqueness: { scope: :project_id }, allow_nil: true
  validates :kind, uniqueness: { scope: :project_id }, if: :canonical_kind?
  validate :kind_is_immutable, on: :update

  private

  def canonical_kind?
    kind.in?(%w[production staging])
  end

  def kind_is_immutable
    errors.add(:kind, "cannot be changed") if will_save_change_to_kind?
  end

  def normalize_attributes
    self.name = name.to_s.strip
    self.slug = (slug.presence || name).to_s.parameterize
    self.branch = branch.to_s.strip.presence
  end
end

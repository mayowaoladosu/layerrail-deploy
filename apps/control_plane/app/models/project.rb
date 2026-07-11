class Project < ApplicationRecord
  LIFECYCLE_STATES = {
    active: "active",
    deletion_requested: "deletion_requested",
    draining: "draining",
    deleting_resources: "deleting_resources",
    tombstoned: "tombstoned",
    permanently_deleted: "permanently_deleted"
  }.freeze

  belongs_to :organization
  has_many :environments, dependent: :restrict_with_exception
  has_many :configuration_versions, dependent: :restrict_with_exception
  has_many :services, dependent: :restrict_with_exception

  enum :lifecycle_state, LIFECYCLE_STATES, prefix: true, validate: true

  before_validation :normalize_attributes

  validates :name,
    presence: true,
    length: { maximum: 120 },
    uniqueness: { scope: :organization_id, case_sensitive: false }
  validates :slug,
    presence: true,
    length: { maximum: 64 },
    format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/ },
    uniqueness: { scope: :organization_id }

  private

  def normalize_attributes
    self.name = name.to_s.strip
    self.slug = (slug.presence || name).to_s.parameterize
  end
end

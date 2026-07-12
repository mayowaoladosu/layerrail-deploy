class Organization < ApplicationRecord
  has_many :memberships, dependent: :restrict_with_exception
  has_many :git_installations, dependent: :restrict_with_exception
  has_many :configuration_versions, dependent: :restrict_with_exception
  has_many :configuration_snapshots, dependent: :restrict_with_exception
  has_many :deployments, dependent: :restrict_with_exception
  has_many :event_receipts, dependent: :restrict_with_exception
  has_many :outbox_events, dependent: :restrict_with_exception
  has_many :projects, dependent: :restrict_with_exception
  has_many :repository_connections, dependent: :restrict_with_exception
  has_many :users, through: :memberships

  before_validation :normalize_name
  before_validation :normalize_slug

  validates :name, presence: true, length: { maximum: 120 }
  validates :slug,
    presence: true,
    length: { maximum: 64 },
    format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/ },
    uniqueness: true

  private

  def normalize_name
    self.name = name.to_s.strip
  end

  def normalize_slug
    self.slug = (slug.presence || name).to_s.parameterize.first(64).delete_suffix("-")
  end
end

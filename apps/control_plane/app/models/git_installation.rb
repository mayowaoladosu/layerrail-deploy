class GitInstallation < ApplicationRecord
  PROVIDERS = { github: "github" }.freeze
  STATUSES = {
    active: "active",
    suspended: "suspended",
    disconnected: "disconnected"
  }.freeze

  belongs_to :organization
  has_many :repository_connections, dependent: :restrict_with_exception

  enum :provider, PROVIDERS, validate: true
  enum :status, STATUSES, prefix: true, validate: true

  validates :provider_installation_id, presence: true, length: { maximum: 255 }, uniqueness: { scope: :provider }
  validates :account_id, presence: true, length: { maximum: 255 }
  validates :account_login, presence: true, length: { maximum: 255 }
  validates :account_type, inclusion: { in: %w[organization user] }
  validate :permissions_are_bounded

  private

  def permissions_are_bounded
    unless permissions.is_a?(Hash)
      errors.add(:permissions, "must be an object")
      return
    end

    errors.add(:permissions, "is too large") if permissions.to_json.bytesize > 8.kilobytes
  end
end

class Organization < ApplicationRecord
  has_many :memberships, dependent: :restrict_with_exception
  has_many :git_installations, dependent: :restrict_with_exception
  has_many :configuration_versions, dependent: :restrict_with_exception
  has_many :configuration_snapshots, dependent: :restrict_with_exception
  has_many :deployments, dependent: :restrict_with_exception
  has_many :projects, dependent: :restrict_with_exception
  has_many :repository_connections, dependent: :restrict_with_exception
  has_many :users, through: :memberships

  before_validation :normalize_name

  validates :name, presence: true, length: { maximum: 120 }

  private

  def normalize_name
    self.name = name.to_s.strip
  end
end

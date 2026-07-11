class User < ApplicationRecord
  has_many :memberships, dependent: :restrict_with_exception
  has_many :organizations, through: :memberships

  before_validation :normalize_attributes

  validates :email,
    presence: true,
    length: { maximum: 320 },
    format: { with: URI::MailTo::EMAIL_REGEXP },
    uniqueness: { case_sensitive: false }
  validates :name, presence: true, length: { maximum: 120 }

  private

  def normalize_attributes
    self.email = email.to_s.strip.downcase
    self.name = name.to_s.strip
  end
end

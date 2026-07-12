class AuthenticationRequestAttempt < ApplicationRecord
  before_create :assign_id

  validates :email_digest, presence: true, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :ip_digest, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true

  private

  def assign_id
    self.id ||= SecureRandom.uuid_v7
  end
end

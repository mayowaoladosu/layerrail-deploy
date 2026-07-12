class RodauthLoginClaim < ApplicationRecord
  before_create :assign_id

  validates :token_digest, presence: true, format: { with: /\A[0-9a-f]{64}\z/ }

  private

  def assign_id
    self.id ||= SecureRandom.uuid_v7
  end
end

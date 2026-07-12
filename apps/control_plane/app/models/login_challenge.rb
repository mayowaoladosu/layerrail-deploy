class LoginChallenge < ApplicationRecord
  PURPOSES = { email_login: "email_login" }.freeze

  enum :purpose, PURPOSES, validate: true

  encrypts :token

  attr_readonly :email,
    :purpose,
    :token_digest,
    :requested_ip_digest,
    :expires_at

  before_update :protect_lifecycle
  before_destroy :prevent_destruction

  validates :email,
    presence: true,
    length: { maximum: 320 },
    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :token_digest, format: { with: /\A[0-9a-f]{64}\z/ }, uniqueness: true
  validates :requested_ip_digest, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validates :expires_at, presence: true
  validate :email_is_normalized
  validate :consumption_is_consistent

  def inspect
    "#<#{self.class.name} id=#{id.inspect} purpose=#{purpose.inspect} email=[FILTERED] token=[REDACTED]>"
  end

  private

  def protect_lifecycle
    if consumed_at_in_database
      errors.add(:base, "Consumed login challenges are immutable")
      throw :abort
    end

    allowed = %w[token delivered_at consumed_at updated_at]
    return if (changes.keys - allowed).empty?

    errors.add(:base, "Login challenge update is not allowed")
    throw :abort
  end

  def prevent_destruction
    errors.add(:base, "Login challenges are append-only")
    throw :abort
  end

  def email_is_normalized
    errors.add(:email, "must be normalized") unless email == email.to_s.strip.downcase
  end

  def consumption_is_consistent
    if consumed_at
      errors.add(:token, "must be cleared after consumption") if token
    else
      errors.add(:token, "must be present before consumption") if token.blank?
    end
  end
end

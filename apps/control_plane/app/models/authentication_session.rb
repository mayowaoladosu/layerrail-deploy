class AuthenticationSession < ApplicationRecord
  KINDS = %w[web api].index_with(&:itself).freeze
  ASSURANCE_LEVELS = %w[single_factor multi_factor].index_with(&:itself).freeze

  belongs_to :user

  enum :kind, KINDS, prefix: true, validate: true
  enum :assurance_level, ASSURANCE_LEVELS, prefix: true, validate: true

  attr_readonly :user_id,
    :kind,
    :assurance_level,
    :token_digest,
    :issued_at,
    :expires_at,
    :ip_digest,
    :user_agent_digest

  before_update :protect_lifecycle
  before_destroy :prevent_destruction

  validates :token_digest, format: { with: /\A[0-9a-f]{64}\z/ }, uniqueness: true
  validates :issued_at, :expires_at, presence: true
  validates :revoked_reason, presence: true, length: { maximum: 120 }, if: :revoked_at?
  validates :revoked_reason, absence: true, unless: :revoked_at?
  validates :ip_digest, :user_agent_digest, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validate :expiry_follows_issue

  def inspect
    "#<#{self.class.name} id=#{id.inspect} user_id=#{user_id.inspect} kind=#{kind.inspect} token=[REDACTED]>"
  end

  private

  def protect_lifecycle
    if revoked_at_in_database
      errors.add(:base, "Revoked authentication sessions are immutable")
      throw :abort
    end

    allowed = if will_save_change_to_revoked_at?
      %w[revoked_at revoked_reason updated_at]
    else
      %w[last_used_at updated_at]
    end
    return if (changes.keys - allowed).empty?

    errors.add(:base, "Authentication session update is not allowed")
    throw :abort
  end

  def prevent_destruction
    errors.add(:base, "Authentication sessions are append-only")
    throw :abort
  end

  def expiry_follows_issue
    return unless issued_at && expires_at

    errors.add(:expires_at, "must follow issuance") unless expires_at > issued_at
  end
end

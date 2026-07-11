class AuthorizationContext
  attr_reader :principal, :organization, :membership

  def self.build(principal:, organization:)
    membership = if principal&.persisted? && organization&.persisted?
      Membership.find_by(user_id: principal.id, organization_id: organization.id)
    end

    new(principal:, organization:, membership:)
  end

  def member?
    membership.present? &&
      membership.user_id == principal&.id &&
      membership.organization_id == organization&.id
  end

  def role?(*roles)
    member? && roles.map(&:to_s).include?(membership.role)
  end

  def selected?(record)
    return false unless organization

    if record.is_a?(Organization)
      record.id == organization.id
    elsif record.respond_to?(:organization_id)
      record.organization_id == organization.id
    else
      false
    end
  end

  def initialize(principal:, organization:, membership:)
    @principal = principal
    @organization = organization
    @membership = membership
    freeze
  end

  private_class_method :new
end

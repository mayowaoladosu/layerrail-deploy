module Authentication
  class IdentityBootstrap
    class InvalidEmail < StandardError; end

    def self.prepare(email)
      normalized_email = normalize_email(email)

      ApplicationRecord.transaction(requires_new: true) do
        advisory_lock!("identity:#{normalized_email}")
        user = User.find_by(email: normalized_email)

        if user
          if user.authentication_state_bootstrap_candidate? && Organization.exists?
            user.update!(authentication_state: :blocked)
            return nil
          end

          return user unless user.authentication_state_blocked?
        end

        return nil if Organization.exists?

        User.create!(
          email: normalized_email,
          name: display_name(normalized_email),
          authentication_state: :bootstrap_candidate
        )
      end
    rescue InvalidEmail
      nil
    end

    def self.activate(user_id)
      ApplicationRecord.transaction(requires_new: true) do
        advisory_lock!("authentication:bootstrap")
        user = User.lock.find_by(id: user_id)
        return false unless user
        return true if user.authentication_state_active?
        return false unless user.authentication_state_bootstrap_candidate?

        if Organization.exists?
          user.update!(authentication_state: :blocked)
          return false
        end

        user.update!(authentication_state: :active)
        Organizations::Create.call(
          principal: user,
          name: "#{user.name.first(100)} Organization"
        )
        true
      end
    end

    def self.normalize_email(value)
      email = value.to_s.strip.downcase
      valid = email.present? && email.length <= 320 && URI::MailTo::EMAIL_REGEXP.match?(email)
      raise InvalidEmail unless valid

      email
    end

    def self.display_name(value)
      source = value.to_s.split("@", 2).first
      name = source.tr("._-", " ").squish.titleize.first(120)
      name.presence || "LayerRail User"
    end

    def self.advisory_lock!(key)
      quoted_key = ApplicationRecord.connection.quote(key)
      ApplicationRecord.connection.execute(
        "SELECT pg_advisory_xact_lock(hashtextextended(#{quoted_key}, 0))"
      )
    end
    private_class_method :advisory_lock!
  end
end

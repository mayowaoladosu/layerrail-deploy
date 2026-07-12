module Authentication
  class LoginClaims
    def self.claim(token)
      RodauthLoginClaim.create!(
        token_digest: Digest::SHA256.hexdigest(token.to_s)
      )
      true
    rescue ActiveRecord::RecordNotUnique
      false
    end
  end
end

class RodauthMailer < ApplicationMailer
  default to: -> { @rodauth.email_to }

  def email_auth(name, account_id, key)
    @rodauth = rodauth(name, account_id) { @email_auth_key_value = key }
    @account = @rodauth.rails_account

    mail subject: @rodauth.email_auth_email_subject
  end

  private

  def rodauth(name, account_id, &block)
    instance = RodauthApp.rodauth(name).allocate
    instance.account_from_id(account_id)
    instance.instance_eval(&block) if block
    instance
  end
end

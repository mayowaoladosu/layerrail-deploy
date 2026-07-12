require "rails_helper"

RSpec.describe RodauthMailer do
  around do |example|
    previous_key = Resend.api_key
    Resend.api_key = "resend-test-key"
    example.run
  ensure
    Resend.api_key = previous_key
  end

  it "builds the multipart passwordless email expected by Resend" do
    user = User.create!(email: "resend-mailer@example.com", name: "Resend Mailer")
    mail = described_class.email_auth(nil, user.id, "one-time-key").message
    payload = Resend::Mailer.new({}).build_resend_params(mail)

    expect(payload).to include(
      from: mail[:from].formatted.first,
      to: [ user.email ],
      subject: "Your LayerRail Deploy sign-in link"
    )
    expect(payload.fetch(:html)).to include("Continue to LayerRail Deploy", "/auth/verify?key=")
    expect(payload.fetch(:text)).to include("Sign in to LayerRail Deploy", "/auth/verify?key=")
    expect(payload.to_json).not_to include("resend-test-key")
  end
end

require "rails_helper"
require Rails.root.join("config/email_delivery")

RSpec.describe ControlPlane::EmailDelivery do
  def mailer_config
    Struct.new(:delivery_method, :smtp_settings, :file_settings).new
  end

  it "uses Resend when an API key is configured" do
    mailer = mailer_config

    described_class.configure(
      mailer,
      environment: :production,
      root: Rails.root,
      env: { "RESEND_API_KEY" => "resend-test-key" }
    )

    expect(mailer.delivery_method).to eq(:resend)
    expect(mailer.smtp_settings).to be_nil
  end

  it "keeps complete SMTP configuration as an explicit override" do
    mailer = mailer_config

    described_class.configure(
      mailer,
      environment: :production,
      root: Rails.root,
      env: {
        "RESEND_API_KEY" => "resend-test-key",
        "SMTP_HOST" => "smtp.example.com",
        "SMTP_PORT" => "2525",
        "SMTP_USERNAME" => "mailer",
        "SMTP_PASSWORD" => "password"
      }
    )

    expect(mailer.delivery_method).to eq(:smtp)
    expect(mailer.smtp_settings).to include(
      address: "smtp.example.com",
      port: 2525,
      user_name: "mailer",
      authentication: :plain,
      enable_starttls_auto: true
    )
  end

  it "ignores partial SMTP settings and uses Resend" do
    mailer = mailer_config

    described_class.configure(
      mailer,
      environment: :production,
      root: Rails.root,
      env: {
        "RESEND_API_KEY" => "resend-test-key",
        "SMTP_HOST" => "smtp.example.com"
      }
    )

    expect(mailer.delivery_method).to eq(:resend)
  end

  it "writes development email to disk without provider credentials" do
    mailer = mailer_config

    described_class.configure(
      mailer,
      environment: :development,
      root: Rails.root,
      env: {}
    )

    expect(mailer.delivery_method).to eq(:file)
    expect(mailer.file_settings).to eq(location: Rails.root.join("tmp/mails"))
  end

  it "fails production boot without a complete email provider" do
    mailer = mailer_config

    expect do
      described_class.configure(
        mailer,
        environment: :production,
        root: Rails.root,
        env: { "SMTP_HOST" => "smtp.example.com" }
      )
    end.to raise_error(KeyError, /RESEND_API_KEY or complete SMTP settings/)
  end
end

# frozen_string_literal: true

require 'rails_helper'

describe Admin::EmailController do
  fab!(:admin) { Fabricate(:admin) }
  fab!(:email_log) { Fabricate(:email_log) }

  before do
    sign_in(admin)
  end

  it "is a subclass of AdminController" do
    expect(Admin::EmailController < Admin::AdminController).to eq(true)
  end

  describe '#index' do
    before do
      Admin::EmailController.any_instance
        .expects(:action_mailer_settings)
        .returns(
          username: 'username',
          password: 'secret'
        )
    end

    it 'does not include the password in the response' do
      get "/admin/email.json"
      mail_settings = JSON.parse(response.body)['settings']

      expect(
        mail_settings.select { |setting| setting['name'] == 'password' }
      ).to be_empty
    end
  end

  describe '#sent' do
    fab!(:post) { Fabricate(:post) }
    fab!(:email_log) { Fabricate(:email_log, post: post) }

    let(:post_reply_key) do
      Fabricate(:post_reply_key, post: post, user: email_log.user)
    end

    it "should return the right response" do
      email_log
      get "/admin/email/sent.json"

      expect(response.status).to eq(200)
      log = JSON.parse(response.body).first
      expect(log["id"]).to eq(email_log.id)
      expect(log["reply_key"]).to eq(nil)

      post_reply_key

      get "/admin/email/sent.json"

      expect(response.status).to eq(200)
      log = JSON.parse(response.body).first
      expect(log["id"]).to eq(email_log.id)
      expect(log["reply_key"]).to eq(post_reply_key.reply_key)
    end

    it 'should be able to filter by reply key' do
      email_log_2 = Fabricate(:email_log, post: post)

      post_reply_key_2 = Fabricate(:post_reply_key,
        post: post,
        user: email_log_2.user,
        reply_key: "2d447423-c625-4fb9-8717-ff04ac60eee8"
      )

      [
        "17ff04",
        "2d447423c6254fb98717ff04ac60eee8"
      ].each do |reply_key|
        get "/admin/email/sent.json", params: {
          reply_key: reply_key
        }

        expect(response.status).to eq(200)

        logs = JSON.parse(response.body)

        expect(logs.size).to eq(1)
        expect(logs.first["reply_key"]).to eq(post_reply_key_2.reply_key)
      end
    end
  end

  describe '#skipped' do
    fab!(:user) { Fabricate(:user) }
    fab!(:log1) { Fabricate(:skipped_email_log, user: user, created_at: 20.minutes.ago) }
    fab!(:log2) { Fabricate(:skipped_email_log, created_at: 10.minutes.ago) }

    it "succeeds" do
      get "/admin/email/skipped.json"

      expect(response.status).to eq(200)

      logs = JSON.parse(response.body)

      expect(logs.first["id"]).to eq(log2.id)
      expect(logs.last["id"]).to eq(log1.id)
    end

    describe 'when filtered by username' do
      it 'should return the right response' do
        get "/admin/email/skipped.json", params: {
          user: user.username
        }

        expect(response.status).to eq(200)

        logs = JSON.parse(response.body)

        expect(logs.count).to eq(1)
        expect(logs.first["id"]).to eq(log1.id)
      end
    end
  end

  describe '#test' do
    it 'raises an error without the email parameter' do
      post "/admin/email/test.json"
      expect(response.status).to eq(400)
    end

    context 'with an email address' do
      it 'enqueues a test email job' do
        post "/admin/email/test.json", params: { email_address: 'eviltrout@test.domain' }

        expect(response.status).to eq(200)
        expect(ActionMailer::Base.deliveries.map(&:to).flatten).to include('eviltrout@test.domain')
      end
    end

    context 'with SiteSetting.disable_emails' do
      fab!(:eviltrout) { Fabricate(:evil_trout) }
      fab!(:admin) { Fabricate(:admin) }

      it 'bypasses disable when setting is "yes"' do
        SiteSetting.disable_emails = 'yes'
        post "/admin/email/test.json", params: { email_address: admin.email }

        expect(ActionMailer::Base.deliveries.first.to).to contain_exactly(
          admin.email
        )

        incoming = JSON.parse(response.body)
        expect(incoming['sent_test_email_message']).to eq(I18n.t("admin.email.sent_test"))
      end

      it 'bypasses disable when setting is "non-staff"' do
        SiteSetting.disable_emails = 'non-staff'

        post "/admin/email/test.json", params: { email_address: eviltrout.email }

        expect(ActionMailer::Base.deliveries.first.to).to contain_exactly(
          eviltrout.email
        )

        incoming = JSON.parse(response.body)
        expect(incoming['sent_test_email_message']).to eq(I18n.t("admin.email.sent_test"))
      end

      it 'works when setting is "no"' do
        SiteSetting.disable_emails = 'no'

        post "/admin/email/test.json", params: { email_address: eviltrout.email }

        expect(ActionMailer::Base.deliveries.first.to).to contain_exactly(
          eviltrout.email
        )

        incoming = JSON.parse(response.body)
        expect(incoming['sent_test_email_message']).to eq(I18n.t("admin.email.sent_test"))
      end
    end
  end

  describe '#preview_digest' do
    it 'raises an error without the last_seen_at parameter' do
      get "/admin/email/preview-digest.json"
      expect(response.status).to eq(400)
    end

    it "returns the right response when username is invalid" do
      get "/admin/email/preview-digest.json", params: {
        last_seen_at: 1.week.ago, username: "somerandomeusername"
      }

      expect(response.status).to eq(400)
    end

    it "previews the digest" do
      get "/admin/email/preview-digest.json", params: {
        last_seen_at: 1.week.ago, username: admin.username
      }
      expect(response.status).to eq(200)
    end
  end

  describe '#handle_mail' do
    it 'should enqueue the right job' do
      expect { post "/admin/email/handle_mail.json", params: { email: email('cc') } }
        .to change { Jobs::ProcessEmail.jobs.count }.by(1)
      expect(response.status).to eq(200)
    end
  end

  describe '#rejected' do
    it 'should provide a string for a blank error' do
      Fabricate(:incoming_email, error: "")
      get "/admin/email/rejected.json"
      expect(response.status).to eq(200)
      rejected = JSON.parse(response.body)
      expect(rejected.first['error']).to eq(I18n.t("emails.incoming.unrecognized_error"))
    end
  end

  describe '#incoming' do
    it 'should provide a string for a blank error' do
      incoming_email = Fabricate(:incoming_email, error: "")
      get "/admin/email/incoming/#{incoming_email.id}.json"
      expect(response.status).to eq(200)
      incoming = JSON.parse(response.body)
      expect(incoming['error']).to eq(I18n.t("emails.incoming.unrecognized_error"))
    end
  end

  describe '#incoming_from_bounced' do
    it 'raises an error when the email log entry does not exist' do
      get "/admin/email/incoming_from_bounced/12345.json"
      expect(response.status).to eq(404)

      json = JSON.parse(response.body)
      expect(json["errors"]).to include("Discourse::InvalidParameters")
    end

    it 'raises an error when the email log entry is not marked as bounced' do
      get "/admin/email/incoming_from_bounced/#{email_log.id}.json"
      expect(response.status).to eq(404)

      json = JSON.parse(response.body)
      expect(json["errors"]).to include("Discourse::InvalidParameters")
    end

    context 'bounced email log entry exists' do
      fab!(:email_log) { Fabricate(:email_log, bounced: true, bounce_key: SecureRandom.hex) }
      let(:error_message) { "Email::Receiver::BouncedEmailError" }

      it 'returns an incoming email sent to the reply_by_email_address' do
        SiteSetting.reply_by_email_address = "replies+%{reply_key}@example.com"

        Fabricate(:incoming_email,
                  is_bounce: true,
                  error: error_message,
                  to_addresses: Email::Sender.bounce_address(email_log.bounce_key)
        )

        get "/admin/email/incoming_from_bounced/#{email_log.id}.json"
        expect(response.status).to eq(200)

        json = JSON.parse(response.body)
        expect(json["error"]).to eq(error_message)
      end

      it 'returns an incoming email sent to the notification_email address' do
        Fabricate(:incoming_email,
                  is_bounce: true,
                  error: error_message,
                  to_addresses: SiteSetting.notification_email.sub("@", "+verp-#{email_log.bounce_key}@")
        )

        get "/admin/email/incoming_from_bounced/#{email_log.id}.json"
        expect(response.status).to eq(200)

        json = JSON.parse(response.body)
        expect(json["error"]).to eq(error_message)
      end

      it 'raises an error if the bounce_key is blank' do
        email_log.update(bounce_key: nil)

        get "/admin/email/incoming_from_bounced/#{email_log.id}.json"
        expect(response.status).to eq(404)

        json = JSON.parse(response.body)
        expect(json["errors"]).to include("Discourse::InvalidParameters")
      end

      it 'raises an error if there is no incoming email' do
        get "/admin/email/incoming_from_bounced/#{email_log.id}.json"
        expect(response.status).to eq(404)

        json = JSON.parse(response.body)
        expect(json["errors"]).to include("Discourse::NotFound")
      end
    end
  end

  describe '#advanced_test' do
    it 'should ...' do
      email = <<~EMAIL
        From: "somebody" <somebody@example.com>
        To: someone@example.com
        Date: Mon, 3 Dec 2018 00:00:00 -0000
        Subject: This is some subject
        Content-Type: text/plain; charset="UTF-8"

        Hello, this is a test!

        ---

        This part should be elided.
      EMAIL
      post "/admin/email/advanced-test.json", params: { email: email }
      expect(response.status).to eq(200)
      incoming = JSON.parse(response.body)
      expect(incoming['format']).to eq(1)
      expect(incoming['text']).to eq("Hello, this is a test!")
      expect(incoming['elided']).to eq("---\n\nThis part should be elided.")
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'
require 'email/sender'

describe Email::Sender do
  fab!(:post) { Fabricate(:post) }

  context "disable_emails is enabled" do
    fab!(:user) { Fabricate(:user) }
    fab!(:moderator) { Fabricate(:moderator) }

    context "disable_emails is enabled for everyone" do
      before { SiteSetting.disable_emails = "yes" }

      it "doesn't deliver mail when mails are disabled" do
        message = UserNotifications.email_login(moderator)
        Email::Sender.new(message, :email_login).send

        expect(ActionMailer::Base.deliveries).to eq([])
      end

      it "delivers mail when mails are disabled but the email_type is admin_login" do
        message = UserNotifications.admin_login(moderator)
        Email::Sender.new(message, :admin_login).send

        expect(ActionMailer::Base.deliveries.first.to).to eq([moderator.email])
      end

      it "delivers mail when mails are disabled but the email_type is test_message" do
        message = TestMailer.send_test(moderator.email)
        Email::Sender.new(message, :test_message).send

        expect(ActionMailer::Base.deliveries.first.to).to eq([moderator.email])
      end
    end

    context "disable_emails is enabled for non-staff users" do
      before { SiteSetting.disable_emails = "non-staff" }

      it "doesn't deliver mail to normal user" do
        Mail::Message.any_instance.expects(:deliver_now).never
        message = Mail::Message.new(to: user.email, body: "hello")
        expect(Email::Sender.new(message, :hello).send).to eq(nil)
      end

      it "delivers mail to staff user" do
        Mail::Message.any_instance.expects(:deliver_now).once
        message = Mail::Message.new(to: moderator.email, body: "hello")
        Email::Sender.new(message, :hello).send
      end
    end
  end

  it "doesn't deliver mail when the message is of type NullMail" do
    Mail::Message.any_instance.expects(:deliver_now).never
    message = ActionMailer::Base::NullMail.new
    expect(Email::Sender.new(message, :hello).send).to eq(nil)
  end

  it "doesn't deliver mail when the message is nil" do
    Mail::Message.any_instance.expects(:deliver_now).never
    Email::Sender.new(nil, :hello).send
  end

  it "doesn't deliver when the to address is nil" do
    message = Mail::Message.new(body: 'hello')
    message.expects(:deliver_now).never
    Email::Sender.new(message, :hello).send
  end

  it "doesn't deliver when the to address uses the .invalid tld" do
    message = Mail::Message.new(body: 'hello', to: 'myemail@example.invalid')
    message.expects(:deliver_now).never
    expect { Email::Sender.new(message, :hello).send }.
      to change { SkippedEmailLog.where(reason_type: SkippedEmailLog.reason_types[:sender_message_to_invalid]).count }.by(1)
  end

  it "doesn't deliver when the body is nil" do
    message = Mail::Message.new(to: 'eviltrout@test.domain')
    message.expects(:deliver_now).never
    Email::Sender.new(message, :hello).send
  end

  context "host_for" do
    it "defaults to localhost" do
      expect(Email::Sender.host_for(nil)).to eq("localhost")
    end

    it "returns localhost for a weird host" do
      expect(Email::Sender.host_for("this is not a real host")).to eq("localhost")
    end

    it "parses hosts from urls" do
      expect(Email::Sender.host_for("http://meta.discourse.org")).to eq("meta.discourse.org")
    end

    it "downcases hosts" do
      expect(Email::Sender.host_for("http://ForumSite.com")).to eq("forumsite.com")
    end

  end

  context 'with a valid message' do

    let(:reply_key) { "abcd" * 8 }

    let(:message) do
      message = Mail::Message.new to: 'eviltrout@test.domain',
                                  body: '**hello**'
      message.stubs(:deliver_now)
      message
    end

    let(:email_sender) { Email::Sender.new(message, :valid_type) }

    it 'calls deliver' do
      message.expects(:deliver_now).once
      email_sender.send
    end

    context "doesn't add return_path when no plus addressing" do
      before { SiteSetting.reply_by_email_address = '%{reply_key}@test.com' }

      it 'should not set the return_path' do
        email_sender.send
        expect(message.header[:return_path].to_s).to eq("")
      end
    end

    context "adds return_path with plus addressing" do
      before { SiteSetting.reply_by_email_address = 'replies+%{reply_key}@test.com' }

      it 'should set the return_path' do
        email_sender.send
        expect(message.header[:return_path].to_s).to eq("replies+verp-#{EmailLog.last.bounce_key}@test.com")
      end
    end

    context "adds a List-ID header to identify the forum" do
      fab!(:category) { Fabricate(:category, name: 'Name With Space') }
      fab!(:topic) { Fabricate(:topic, category: category) }
      fab!(:post) { Fabricate(:post, topic: topic) }

      before do
        message.header['X-Discourse-Post-Id']  = post.id
        message.header['X-Discourse-Topic-Id'] = topic.id
      end

      it 'should add the right header' do
        email_sender.send

        expect(message.header['List-ID']).to be_present
        expect(message.header['List-ID'].to_s).to match('name-with-space')
      end
    end

    context "adds a Message-ID header even when topic id is not present" do

      it 'should add the right header' do
        email_sender.send

        expect(message.header['Message-ID']).to be_present
      end
    end

    context "adds Precedence header" do
      fab!(:topic) { Fabricate(:topic) }
      fab!(:post) { Fabricate(:post, topic: topic) }

      before do
        message.header['X-Discourse-Post-Id']  = post.id
        message.header['X-Discourse-Topic-Id'] = topic.id
      end

      it 'should add the right header' do
        email_sender.send
        expect(message.header['Precedence']).to be_present
      end
    end

    context "removes custom Discourse headers from topic notification mails" do
      fab!(:topic) { Fabricate(:topic) }
      fab!(:post) { Fabricate(:post, topic: topic) }

      before do
        message.header['X-Discourse-Post-Id']  = post.id
        message.header['X-Discourse-Topic-Id'] = topic.id
      end

      it 'should remove the right headers' do
        email_sender.send
        expect(message.header['X-Discourse-Topic-Id']).not_to be_present
        expect(message.header['X-Discourse-Post-Id']).not_to be_present
        expect(message.header['X-Discourse-Reply-Key']).not_to be_present
      end
    end

    context "removes custom Discourse headers from digest/registration/other mails" do
      it 'should remove the right headers' do
        email_sender.send
        expect(message.header['X-Discourse-Topic-Id']).not_to be_present
        expect(message.header['X-Discourse-Post-Id']).not_to be_present
        expect(message.header['X-Discourse-Reply-Key']).not_to be_present
      end
    end

    context "email threading" do
      fab!(:topic) { Fabricate(:topic) }

      fab!(:post_1) { Fabricate(:post, topic: topic, post_number: 1) }
      fab!(:post_2) { Fabricate(:post, topic: topic, post_number: 2) }
      fab!(:post_3) { Fabricate(:post, topic: topic, post_number: 3) }
      fab!(:post_4) { Fabricate(:post, topic: topic, post_number: 4) }

      let!(:post_reply_1_4) { PostReply.create(post: post_1, reply: post_4) }
      let!(:post_reply_2_4) { PostReply.create(post: post_2, reply: post_4) }
      let!(:post_reply_3_4) { PostReply.create(post: post_3, reply: post_4) }

      before { message.header['X-Discourse-Topic-Id'] = topic.id }

      it "doesn't set the 'In-Reply-To' and 'References' headers on the first post" do
        message.header['X-Discourse-Post-Id'] = post_1.id

        email_sender.send

        expect(message.header['Message-Id'].to_s).to eq("<topic/#{topic.id}@test.localhost>")
        expect(message.header['In-Reply-To'].to_s).to be_blank
        expect(message.header['References'].to_s).to be_blank
      end

      it "sets the 'In-Reply-To' header to the topic by default" do
        message.header['X-Discourse-Post-Id'] = post_2.id

        email_sender.send

        expect(message.header['Message-Id'].to_s).to eq("<topic/#{topic.id}/#{post_2.id}@test.localhost>")
        expect(message.header['In-Reply-To'].to_s).to eq("<topic/#{topic.id}@test.localhost>")
      end

      it "sets the 'In-Reply-To' header to the newest replied post" do
        message.header['X-Discourse-Post-Id'] = post_4.id

        email_sender.send

        expect(message.header['Message-Id'].to_s).to eq("<topic/#{topic.id}/#{post_4.id}@test.localhost>")
        expect(message.header['In-Reply-To'].to_s).to eq("<topic/#{topic.id}/#{post_3.id}@test.localhost>")
      end

      it "sets the 'References' header to the topic and all replied posts" do
        message.header['X-Discourse-Post-Id'] = post_4.id

        email_sender.send

        references = [
          "<topic/#{topic.id}@test.localhost>",
          "<topic/#{topic.id}/#{post_3.id}@test.localhost>",
          "<topic/#{topic.id}/#{post_2.id}@test.localhost>",
        ]

        expect(message.header['References'].to_s).to eq(references.join(" "))
      end

      it "uses the incoming_email message_id when available" do
        topic_incoming_email  = IncomingEmail.create(topic: topic, post: post_1, message_id: "foo@bar")
        post_2_incoming_email = IncomingEmail.create(topic: topic, post: post_2, message_id: "bar@foo")
        post_4_incoming_email = IncomingEmail.create(topic: topic, post: post_4, message_id: "wat@wat")

        message.header['X-Discourse-Post-Id'] = post_4.id

        email_sender.send

        expect(message.header['Message-Id'].to_s).to eq("<#{post_4_incoming_email.message_id}>")

        references = [
          "<#{topic_incoming_email.message_id}>",
          "<topic/#{topic.id}/#{post_3.id}@test.localhost>",
          "<#{post_2_incoming_email.message_id}>",
        ]

        expect(message.header['References'].to_s).to eq(references.join(" "))
      end

    end

    context "merges custom mandrill header" do
      before do
        ActionMailer::Base.smtp_settings[:address] = "smtp.mandrillapp.com"
        message.header['X-MC-Metadata'] = { foo: "bar" }.to_json
      end

      it 'should set the right header' do
        email_sender.send
        expect(message.header['X-MC-Metadata'].to_s).to match(message.message_id)
      end
    end

    context "merges custom sparkpost header" do
      before do
        ActionMailer::Base.smtp_settings[:address] = "smtp.sparkpostmail.com"
        message.header['X-MSYS-API'] = { foo: "bar" }.to_json
      end

      it 'should set the right header' do
        email_sender.send
        expect(message.header['X-MSYS-API'].to_s).to match(message.message_id)
      end
    end

    context 'email logs' do
      let(:email_log) { EmailLog.last }

      it 'should create the right log' do
        expect do
          email_sender.send
        end.to_not change { PostReplyKey.count }

        expect(email_log).to be_present
        expect(email_log.email_type).to eq('valid_type')
        expect(email_log.to_address).to eq('eviltrout@test.domain')
        expect(email_log.user_id).to be_blank
      end
    end

    context "email log with a post id and topic id" do
      let(:topic) { post.topic }

      before do
        message.header['X-Discourse-Post-Id'] = post.id
        message.header['X-Discourse-Topic-Id'] = topic.id
      end

      let(:email_log) { EmailLog.last }

      it 'should create the right log' do
        email_sender.send
        expect(email_log.post_id).to eq(post.id)
        expect(email_log.topic.id).to eq(topic.id)
      end
    end

    context 'email parts' do
      it 'should contain the right message' do
        email_sender.send

        expect(message).to be_multipart
        expect(message.text_part.content_type).to eq('text/plain; charset=UTF-8')
        expect(message.html_part.content_type).to eq('text/html; charset=UTF-8')
        expect(message.html_part.body.to_s).to match("<p><strong>hello</strong></p>")
      end
    end
  end

  context "with attachments" do
    fab!(:small_pdf) do
      SiteSetting.authorized_extensions = 'pdf'
      UploadCreator.new(file_from_fixtures("small.pdf", "pdf"), "small.pdf")
        .create_for(Discourse.system_user.id)
    end
    fab!(:large_pdf) do
      SiteSetting.authorized_extensions = 'pdf'
      UploadCreator.new(file_from_fixtures("large.pdf", "pdf"), "large.pdf")
        .create_for(Discourse.system_user.id)
    end
    fab!(:csv_file) do
      SiteSetting.authorized_extensions = 'csv'
      UploadCreator.new(file_from_fixtures("words.csv", "csv"), "words.csv")
        .create_for(Discourse.system_user.id)
    end
    fab!(:image) do
      SiteSetting.authorized_extensions = 'png'
      UploadCreator.new(file_from_fixtures("logo.png", "images"), "logo.png")
        .create_for(Discourse.system_user.id)
    end
    fab!(:post) { Fabricate(:post) }
    fab!(:reply) do
      raw = <<~RAW
        Hello world!
        #{UploadMarkdown.new(small_pdf).attachment_markdown}
        #{UploadMarkdown.new(large_pdf).attachment_markdown}
        #{UploadMarkdown.new(image).image_markdown}
        #{UploadMarkdown.new(csv_file).attachment_markdown}
      RAW
      reply = Fabricate(:post, raw: raw, topic: post.topic, user: Fabricate(:user))
      reply.link_post_uploads
      reply
    end
    fab!(:notification) { Fabricate(:posted_notification, user: post.user, post: reply) }
    let(:message) do
      UserNotifications.user_posted(
        post.user,
        post: reply,
        notification_type: notification.notification_type,
        notification_data_hash: notification.data_hash
      )
    end

    it "adds only non-image uploads as attachments to the email" do
      SiteSetting.email_total_attachment_size_limit_kb = 10_000
      Email::Sender.new(message, :valid_type).send

      expect(message.attachments.length).to eq(3)
      expect(message.attachments.map(&:filename))
        .to contain_exactly(*[small_pdf, large_pdf, csv_file].map(&:original_filename))
    end

    it "respects the size limit and attaches only files that fit into the max email size" do
      SiteSetting.email_total_attachment_size_limit_kb = 40
      Email::Sender.new(message, :valid_type).send

      expect(message.attachments.length).to eq(2)
      expect(message.attachments.map(&:filename))
        .to contain_exactly(*[small_pdf, csv_file].map(&:original_filename))
    end

    it "structures the email as a multipart/mixed with a multipart/alternative first part" do
      SiteSetting.email_total_attachment_size_limit_kb = 10_000
      Email::Sender.new(message, :valid_type).send

      expect(message.content_type).to start_with("multipart/mixed")
      expect(message.parts.size).to eq(4)
      expect(message.parts[0].content_type).to start_with("multipart/alternative")
      expect(message.parts[0].parts.size).to eq(2)
    end
  end

  context 'with a deleted post' do

    it 'should skip sending the email' do
      post = Fabricate(:post, deleted_at: 1.day.ago)

      message = Mail::Message.new to: 'disc@ourse.org', body: 'some content'
      message.header['X-Discourse-Post-Id'] = post.id
      message.header['X-Discourse-Topic-Id'] = post.topic_id
      message.expects(:deliver_now).never

      email_sender = Email::Sender.new(message, :valid_type)
      expect { email_sender.send }.to change { SkippedEmailLog.count }

      log = SkippedEmailLog.last
      expect(log.reason_type).to eq(SkippedEmailLog.reason_types[:sender_post_deleted])
    end

  end

  context 'with a deleted topic' do

    it 'should skip sending the email' do
      post = Fabricate(:post, topic: Fabricate(:topic, deleted_at: 1.day.ago))

      message = Mail::Message.new to: 'disc@ourse.org', body: 'some content'
      message.header['X-Discourse-Post-Id'] = post.id
      message.header['X-Discourse-Topic-Id'] = post.topic_id
      message.expects(:deliver_now).never

      email_sender = Email::Sender.new(message, :valid_type)
      expect { email_sender.send }.to change { SkippedEmailLog.count }

      log = SkippedEmailLog.last
      expect(log.reason_type).to eq(SkippedEmailLog.reason_types[:sender_topic_deleted])
    end

  end

  context 'with a user' do
    let(:message) do
      message = Mail::Message.new to: 'eviltrout@test.domain', body: 'test body'
      message.stubs(:deliver_now)
      message
    end

    fab!(:user) { Fabricate(:user) }
    let(:email_sender) { Email::Sender.new(message, :valid_type, user) }

    before do
      email_sender.send
      @email_log = EmailLog.last
    end

    it 'should have the current user_id' do
      expect(@email_log.user_id).to eq(user.id)
    end

    describe "post reply keys" do
      fab!(:post) { Fabricate(:post) }

      before do
        message.header['X-Discourse-Post-Id'] = post.id
        message.header['Reply-To'] = "test-%{reply_key}@test.com"
      end

      describe 'when allow reply by email header is not present' do
        it 'should not create a post reply key' do
          expect { email_sender.send }.to_not change { PostReplyKey.count }
        end
      end

      describe 'when allow reply by email header is present' do
        let(:header) { Email::MessageBuilder::ALLOW_REPLY_BY_EMAIL_HEADER }

        before do
          message.header[header] = "test-%{reply_key}@test.com"
        end

        it 'should create a post reply key' do
          expect { email_sender.send }.to change { PostReplyKey.count }.by(1)
          post_reply_key = PostReplyKey.last

          expect(message.header['Reply-To'].value).to eq(
            "test-#{post_reply_key.reply_key}@test.com"
          )

          expect(message.header[header]).to eq(nil)
          expect(post_reply_key.user_id).to eq(user.id)
          expect(post_reply_key.post_id).to eq(post.id)
          expect { email_sender.send }.to change { PostReplyKey.count }.by(0)
        end
      end
    end
  end

end

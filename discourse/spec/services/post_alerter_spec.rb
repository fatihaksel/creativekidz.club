# frozen_string_literal: true

require 'rails_helper'

RSpec::Matchers.define :add_notification do |user, notification_type|
  match(notify_expectation_failures: true) do |actual|
    notifications = user.notifications
    before = notifications.count

    actual.call

    expect(notifications.count).to eq(before + 1), "expected 1 new notification, got #{notifications.count - before}"

    last_notification_type = notifications.last.notification_type
    expect(last_notification_type).to eq(Notification.types[notification_type]),
                                      "expected notification type to be '#{notification_type}', got '#{Notification.types.key(last_notification_type)}'"
  end

  match_when_negated do |actual|
    expect { actual.call }.to_not change { user.notifications.where(notification_type: Notification.types[notification_type]).count }
  end

  supports_block_expectations
end

RSpec::Matchers.define_negated_matcher :not_add_notification, :add_notification

describe PostAlerter do

  fab!(:evil_trout) { Fabricate(:evil_trout) }
  fab!(:user) { Fabricate(:user) }

  def create_post_with_alerts(args = {})
    post = Fabricate(:post, args)
    PostAlerter.post_created(post)
  end

  context "private message" do
    it "notifies for pms correctly" do
      pm = Fabricate(:topic, archetype: 'private_message', category_id: nil)
      op = Fabricate(:post, user: pm.user)
      pm.allowed_users << pm.user
      PostAlerter.post_created(op)

      reply = Fabricate(:post, user: pm.user, topic: pm, reply_to_post_number: 1)
      PostAlerter.post_created(reply)

      reply2 = Fabricate(:post, topic: pm, reply_to_post_number: 1)
      PostAlerter.post_created(reply2)

      # we get a green notification for a reply
      expect(Notification.where(user_id: pm.user_id).pluck_first(:notification_type)).to eq(Notification.types[:private_message])

      TopicUser.change(pm.user_id, pm.id, notification_level: TopicUser.notification_levels[:tracking])

      Notification.destroy_all

      reply3 = Fabricate(:post, topic: pm)
      PostAlerter.post_created(reply3)

      # no notification cause we are tracking
      expect(Notification.where(user_id: pm.user_id).count).to eq(0)

      Notification.destroy_all

      reply4 = Fabricate(:post, topic: pm, reply_to_post_number: 1)
      PostAlerter.post_created(reply4)

      # yes notification cause we were replied to
      expect(Notification.where(user_id: pm.user_id).count).to eq(1)

    end

    it "triggers :before_create_notifications_for_users" do
      pm = Fabricate(:topic, archetype: 'private_message', category_id: nil)
      op = Fabricate(:post, user: pm.user, topic: pm)
      user1 = Fabricate(:user)
      user2 = Fabricate(:user)
      group = Fabricate(:group, users: [user2])
      pm.allowed_users << user1
      pm.allowed_groups << group
      events = DiscourseEvent.track_events do
        PostAlerter.post_created(op)
      end
      expect(events).to include(event_name: :before_create_notifications_for_users, params: [[user1], op])
      expect(events).to include(event_name: :before_create_notifications_for_users, params: [[user2], op])
    end
  end

  context "unread" do
    it "does not return whispers as unread posts" do
      op = Fabricate(:post)
      _whisper = Fabricate(:post, raw: 'this is a whisper post',
                                  user: Fabricate(:admin),
                                  topic: op.topic,
                                  reply_to_post_number: op.post_number,
                                  post_type: Post.types[:whisper])

      expect(PostAlerter.new.first_unread_post(op.user, op.topic)).to be_blank
    end
  end

  context 'edits' do
    it 'notifies correctly on edits' do
      Jobs.run_immediately!
      PostActionNotifier.enable

      post = Fabricate(:post, raw: 'I love waffles')

      admin = Fabricate(:admin)
      post.revise(admin, raw: 'I made a revision')

      # skip this notification cause we already notified on a similar edit
      freeze_time 2.hours.from_now
      post.revise(admin, raw: 'I made another revision')

      post.revise(Fabricate(:admin), raw: 'I made a revision')

      freeze_time 2.hours.from_now
      post.revise(admin, raw: 'I made another revision')

      expect(Notification.where(post_number: 1, topic_id: post.topic_id).count).to eq(3)
    end

    it 'notifies flaggers when flagged post gets unhidden by edit' do
      post = create_post
      walterwhite = Fabricate(:walter_white)
      coding_horror = Fabricate(:coding_horror)

      PostActionNotifier.enable
      Reviewable.set_priorities(high: 4.0)
      SiteSetting.hide_post_sensitivity = Reviewable.sensitivity[:low]

      PostActionCreator.spam(evil_trout, post)
      PostActionCreator.spam(walterwhite, post)

      post.reload
      expect(post.hidden).to eq(true)

      expect {
        post.revise(post.user, raw: post.raw + " ha I edited it ")
      }.to add_notification(evil_trout, :edited)
        .and add_notification(walterwhite, :edited)

      post.reload
      expect(post.hidden).to eq(false)

      notification = walterwhite.notifications.last
      expect(notification.topic_id).to eq(post.topic.id)
      expect(notification.post_number).to eq(post.post_number)
      expect(notification.data_hash["display_username"]).to eq(post.user.username)

      PostActionCreator.create(coding_horror, post, :spam)
      PostActionCreator.create(walterwhite, post, :off_topic)

      post.reload
      expect(post.hidden).to eq(true)

      expect {
        post.revise(post.user, raw: post.raw + " ha I edited it again ")
      }.to not_add_notification(evil_trout, :edited)
        .and not_add_notification(coding_horror, :edited)
        .and not_add_notification(walterwhite, :edited)
    end
  end

  context 'quotes' do
    let(:category) { Fabricate(:category) }
    let(:topic) { Fabricate(:topic, category: category) }

    it 'does not notify for muted users' do
      post = Fabricate(:post, raw: '[quote="EvilTrout, post:1"]whatup[/quote]', topic: topic)
      MutedUser.create!(user_id: evil_trout.id, muted_user_id: post.user_id)

      expect {
        PostAlerter.post_created(post)
      }.to change(evil_trout.notifications, :count).by(0)
    end

    it 'does not notify for ignored users' do
      post = Fabricate(:post, raw: '[quote="EvilTrout, post:1"]whatup[/quote]', topic: topic)
      IgnoredUser.create!(user_id: evil_trout.id, ignored_user_id: post.user_id)

      expect {
        PostAlerter.post_created(post)
      }.to change(evil_trout.notifications, :count).by(0)
    end

    it 'does not notify for users with new reply notification' do
      post = Fabricate(:post, raw: '[quote="EvilTrout, post:1"]whatup[/quote]', topic: topic)
      notification = Notification.create!(topic: post.topic,
                                          post_number: post.post_number,
                                          read: false,
                                          notification_type: Notification.types[:replied],
                                          user: evil_trout,
                                          data: { topic_title: "test topic" }.to_json
                                         )

      expect {
        PostAlerter.post_created(post)
      }.to change(evil_trout.notifications, :count).by(0)

      notification.destroy
      expect {
        PostAlerter.post_created(post)
      }.to change(evil_trout.notifications, :count).by(1)
    end

    it 'does not collapse quote notifications' do
      expect {
        2.times do
          create_post_with_alerts(
            raw: '[quote="EvilTrout, post:1"]whatup[/quote]',
            topic: topic
          )
        end
      }.to change(evil_trout.notifications, :count).by(2)
    end

    it "won't notify the user a second time on revision" do
      p1 = create_post_with_alerts(raw: '[quote="Evil Trout, post:1"]whatup[/quote]')
      expect {
        p1.revise(p1.user, raw: '[quote="Evil Trout, post:1"]whatup now?[/quote]')
      }.not_to change(evil_trout.notifications, :count)
    end

    it "doesn't notify the poster" do
      topic = create_post_with_alerts.topic
      expect {
        Fabricate(:post, topic: topic, user: topic.user, raw: '[quote="Bruce Wayne, post:1"]whatup[/quote]')
      }.not_to change(topic.user.notifications, :count)
    end

    it "triggers :before_create_notifications_for_users" do
      post = Fabricate(:post, raw: '[quote="EvilTrout, post:1"]whatup[/quote]')
      events = DiscourseEvent.track_events do
        PostAlerter.post_created(post)
      end
      expect(events).to include(event_name: :before_create_notifications_for_users, params: [[evil_trout], post])
    end
  end

  context 'linked' do
    let(:post1) { create_post }
    let(:user) { post1.user }
    let(:linking_post) { create_post(raw: "my magic topic\n##{Discourse.base_url}#{post1.url}") }

    before do
      Jobs.run_immediately!
    end

    it "will notify correctly on linking" do
      linking_post

      expect(user.notifications.count).to eq(1)

      topic = Fabricate(:topic)

      watcher = Fabricate(:user)
      TopicUser.create!(user_id: watcher.id, topic_id: topic.id, notification_level: TopicUser.notification_levels[:watching])

      create_post(topic_id: topic.id, user: user, raw: "my magic topic\n##{Discourse.base_url}#{post1.url}")

      user.reload
      expect(user.notifications.where(notification_type: Notification.types[:linked]).count).to eq(1)

      expect(watcher.notifications.count).to eq(1)

      # don't notify on reflection
      post1.reload
      expect(PostAlerter.new.extract_linked_users(post1).length).to eq(0)
    end

    it "triggers :before_create_notifications_for_users" do
      events = DiscourseEvent.track_events do
        linking_post
      end
      expect(events).to include(event_name: :before_create_notifications_for_users, params: [[user], linking_post])
    end

    it "doesn't notify the linked user if the user is staged and the category is restricted and allows strangers" do
      staged_user = Fabricate(:staged)
      group = Fabricate(:group)
      group_member = Fabricate(:user)
      group.add(group_member)

      private_category = Fabricate(
        :private_category, group: group,
                           email_in: 'test@test.com', email_in_allow_strangers: true
      )

      staged_user_post = create_post(user: staged_user, category: private_category)

      linking = create_post(
        user: group_member,
        category: private_category,
        raw: "my magic topic\n##{Discourse.base_url}#{staged_user_post.url}")

      staged_user.reload
      expect(staged_user.notifications.where(notification_type: Notification.types[:linked]).count).to eq(0)
    end
  end

  context '@group mentions' do

    fab!(:group) { Fabricate(:group, name: 'group', mentionable_level: Group::ALIAS_LEVELS[:everyone]) }
    let(:post) { create_post_with_alerts(raw: "Hello @group how are you?") }
    before { group.add(evil_trout) }

    it 'notifies users correctly' do
      expect {
        post
      }.to change(evil_trout.notifications, :count).by(1)

      expect(GroupMention.count).to eq(1)

      Fabricate(:group, name: 'group-alt', mentionable_level: Group::ALIAS_LEVELS[:everyone])

      expect {
        create_post_with_alerts(raw: "Hello, @group-alt should not trigger a notification?")
      }.to change(evil_trout.notifications, :count).by(0)

      expect(GroupMention.count).to eq(2)

      group.update_columns(mentionable_level: Group::ALIAS_LEVELS[:members_mods_and_admins])
      expect {
        create_post_with_alerts(raw: "Hello @group you are not mentionable")
      }.to change(evil_trout.notifications, :count).by(0)

      expect(GroupMention.count).to eq(3)

      group.update_columns(mentionable_level: Group::ALIAS_LEVELS[:owners_mods_and_admins])
      group.add_owner(user)
      expect {
        create_post_with_alerts(raw: "Hello @group the owner can mention you", user: user)
      }.to change(evil_trout.notifications, :count).by(1)

      expect(GroupMention.count).to eq(4)
    end

    it "triggers :before_create_notifications_for_users" do
      events = DiscourseEvent.track_events do
        post
      end
      expect(events).to include(event_name: :before_create_notifications_for_users, params: [[evil_trout], post])
    end
  end

  context '@mentions' do

    let(:mention_post) { create_post_with_alerts(user: user, raw: 'Hello @eviltrout') }
    let(:topic) { mention_post.topic }

    before do
      Jobs.run_immediately!
    end

    it 'notifies a user' do
      expect {
        mention_post
      }.to change(evil_trout.notifications, :count).by(1)
    end

    it "won't notify the user a second time on revision" do
      mention_post
      expect {
        mention_post.revise(mention_post.user, raw: "New raw content that still mentions @eviltrout")
      }.not_to change(evil_trout.notifications, :count)
    end

    it "doesn't notify the user who created the topic in regular mode" do
      topic.notify_regular!(user)
      mention_post
      expect {
        create_post_with_alerts(user: user, raw: 'second post', topic: topic)
      }.not_to change(user.notifications, :count)
    end

    it "triggers :before_create_notifications_for_users" do
      events = DiscourseEvent.track_events do
        mention_post
      end
      expect(events).to include(event_name: :before_create_notifications_for_users, params: [[evil_trout], mention_post])
    end

    it "notification comes from editor if mention is added later" do
      admin = Fabricate(:admin)
        post = create_post_with_alerts(user: user, raw: 'No mention here.')
        expect {
          post.revise(admin, raw: "Mention @eviltrout in this edit.")
        }.to change(evil_trout.notifications, :count)
        n = evil_trout.notifications.last
        expect(n.data_hash["original_username"]).to eq(admin.username)
    end

    it "doesn't notify the last post editor if they mention themself" do
      post = create_post_with_alerts(user: user, raw: 'Post without a mention.')
      expect {
        post.revise(evil_trout, raw: "O hai, @eviltrout!")
      }.not_to change(evil_trout.notifications, :count)
    end

    fab!(:alice) { Fabricate(:user, username: 'alice') }
    fab!(:bob) { Fabricate(:user, username: 'bob') }
    fab!(:carol) { Fabricate(:admin, username: 'carol') }
    fab!(:dave) { Fabricate(:user, username: 'dave') }
    fab!(:eve) { Fabricate(:user, username: 'eve') }
    fab!(:group) { Fabricate(:group, name: 'group', mentionable_level: Group::ALIAS_LEVELS[:everyone]) }

    before do
      group.bulk_add([alice.id, eve.id])
    end

    def create_post_with_alerts(args = {})
      post = Fabricate(:post, args)
      PostAlerter.post_created(post)
    end

    def set_topic_notification_level(user, topic, level_name)
      TopicUser.change(user.id, topic.id, notification_level: TopicUser.notification_levels[level_name])
    end

    context "topic" do
      fab!(:topic) { Fabricate(:topic, user: alice) }

      [:watching, :tracking, :regular].each do |notification_level|
        context "when notification level is '#{notification_level}'" do
          before do
            set_topic_notification_level(alice, topic, notification_level)
          end

          it "notifies about @username mention" do
            args = { user: bob, topic: topic, raw: 'Hello @alice' }
            expect { create_post_with_alerts(args) }.to add_notification(alice, :mentioned)
          end
        end
      end

      context "when notification level is 'muted'" do
        before do
          set_topic_notification_level(alice, topic, :muted)
        end

        it "does not notify about @username mention" do
          args = { user: bob, topic: topic, raw: 'Hello @alice' }
          expect { create_post_with_alerts(args) }.to_not add_notification(alice, :mentioned)
        end
      end
    end

    context "message to users" do
      fab!(:pm_topic) do
        Fabricate(:private_message_topic,
                  user: alice,
                  topic_allowed_users: [
                    Fabricate.build(:topic_allowed_user, user: alice),
                    Fabricate.build(:topic_allowed_user, user: bob),
                    Fabricate.build(:topic_allowed_user, user: Discourse.system_user)
                  ]
        )
      end

      context "when user is part of conversation" do
        [:watching, :tracking, :regular].each do |notification_level|
          context "when notification level is '#{notification_level}'" do
            before do
              set_topic_notification_level(alice, pm_topic, notification_level)
            end

            it "notifies about @username mention" do
              args = { user: bob, topic: pm_topic, raw: 'Hello @alice' }
              expect { create_post_with_alerts(args) }.to add_notification(alice, :mentioned)
            end

            it "notifies about @username mentions by non-human users" do
              args = { user: Discourse.system_user, topic: pm_topic, raw: 'Hello @alice' }
              expect { create_post_with_alerts(args) }.to add_notification(alice, :mentioned)
            end

            it "notifies about @group mention when allowed user is part of group" do
              args = { user: bob, topic: pm_topic, raw: 'Hello @group' }
              expect { create_post_with_alerts(args) }.to add_notification(alice, :group_mentioned)
            end
          end
        end

        context "when notification level is 'muted'" do
          before do
            set_topic_notification_level(alice, pm_topic, :muted)
          end

          it "does not notify about @username mention" do
            args = { user: bob, topic: pm_topic, raw: 'Hello @alice' }
            expect { create_post_with_alerts(args) }.to_not add_notification(alice, :mentioned)
          end
        end
      end

      context "when user is not part of conversation" do
        it "does not notify about @username mention even though mentioned user is an admin" do
          args = { user: bob, topic: pm_topic, raw: 'Hello @carol' }
          expect { create_post_with_alerts(args) }.to_not add_notification(carol, :mentioned)
        end

        it "does not notify about @username mention by non-human user even though mentioned user is an admin" do
          args = { user: Discourse.system_user, topic: pm_topic, raw: 'Hello @carol' }
          expect { create_post_with_alerts(args) }.to_not add_notification(carol, :mentioned)
        end

        it "does not notify about @username mention when mentioned user is not allowed to see message" do
          args = { user: bob, topic: pm_topic, raw: 'Hello @dave' }
          expect { create_post_with_alerts(args) }.to_not add_notification(dave, :mentioned)
        end

        it "does not notify about @group mention when user is not an allowed user" do
          args = { user: bob, topic: pm_topic, raw: 'Hello @group' }
          expect { create_post_with_alerts(args) }.to_not add_notification(eve, :group_mentioned)
        end
      end
    end

    context "message to group" do

      fab!(:some_group) { Fabricate(:group, name: 'some_group', mentionable_level: Group::ALIAS_LEVELS[:everyone]) }
      fab!(:pm_topic) do
        Fabricate(:private_message_topic,
                  user: alice,
                  topic_allowed_groups: [
                    Fabricate.build(:topic_allowed_group, group: group)
                  ],
                  topic_allowed_users: [
                    Fabricate.build(:topic_allowed_user, user: Discourse.system_user)
                  ]
        )
      end

      before do
        some_group.bulk_add([alice.id, carol.id])
      end

      context "when group is part of conversation" do
        [:watching, :tracking, :regular].each do |notification_level|
          context "when notification level is '#{notification_level}'" do
            before do
              set_topic_notification_level(alice, pm_topic, notification_level)
            end

            it "notifies about @group mention" do
              args = { user: bob, topic: pm_topic, raw: 'Hello @group' }
              expect { create_post_with_alerts(args) }.to add_notification(alice, :group_mentioned)
            end

            it "notifies about @group mentions by non-human users" do
              args = { user: Discourse.system_user, topic: pm_topic, raw: 'Hello @group' }
              expect { create_post_with_alerts(args) }.to add_notification(alice, :group_mentioned)
            end

            it "notifies about @username mention when user belongs to allowed group" do
              args = { user: bob, topic: pm_topic, raw: 'Hello @alice' }
              expect { create_post_with_alerts(args) }.to add_notification(alice, :mentioned)
            end
          end
        end

        context "when notification level is 'muted'" do
          before do
            set_topic_notification_level(alice, pm_topic, :muted)
          end

          it "does not notify about @group mention" do
            args = { user: bob, topic: pm_topic, raw: 'Hello @group' }
            expect { create_post_with_alerts(args) }.to_not add_notification(alice, :group_mentioned)
          end
        end
      end

      context "when group is not part of conversation" do
        it "does not notify about @group mention even though mentioned user is an admin" do
          args = { user: bob, topic: pm_topic, raw: 'Hello @some_group' }
          expect { create_post_with_alerts(args) }.to_not add_notification(carol, :group_mentioned)
        end

        it "does not notify about @group mention by non-human user even though mentioned user is an admin" do
          args = { user: Discourse.system_user, topic: pm_topic, raw: 'Hello @some_group' }
          expect { create_post_with_alerts(args) }.to_not add_notification(carol, :group_mentioned)
        end

        it "does not notify about @username mention when user doesn't belong to allowed group" do
          args = { user: bob, topic: pm_topic, raw: 'Hello @dave' }
          expect { create_post_with_alerts(args) }.to_not add_notification(dave, :mentioned)
        end
      end
    end
  end

  describe ".create_notification" do
    fab!(:topic) { Fabricate(:private_message_topic, user: user, created_at: 1.hour.ago) }
    fab!(:post) { Fabricate(:post, topic: topic, created_at: 1.hour.ago) }
    let(:type) { Notification.types[:private_message] }

    it "creates a notification for PMs" do
      post.revise(user, { raw: 'This is the revised post' }, revised_at: Time.zone.now)

      expect {
        PostAlerter.new.create_notification(user, type, post)
      }.to change { user.notifications.count }.by(1)

      expect(user.notifications.last.data_hash["topic_title"]).to eq(topic.title)
    end

    it "keeps the original title for PMs" do
      original_title = topic.title

      post.revise(user, { title: "This is the revised title" }, revised_at: Time.now)

      expect {
        PostAlerter.new.create_notification(user, type, post)
      }.to change { user.notifications.count }.by(1)

      expect(user.notifications.last.data_hash["topic_title"]).to eq(original_title)
    end

    it "triggers :pre_notification_alert" do
      events = DiscourseEvent.track_events do
        PostAlerter.new.create_notification(user, type, post)
      end

      payload = {
       notification_type: type,
       post_number: post.post_number,
       topic_title: post.topic.title,
       topic_id: post.topic.id,
       excerpt: post.excerpt(400, text_entities: true, strip_links: true, remap_emoji: true),
       username: post.username,
       post_url: post.url
      }

      expect(events).to include(event_name: :pre_notification_alert, params: [user, payload])
    end

    it "does not alert when revising and changing notification type" do
      PostAlerter.new.create_notification(user, type, post)

      post.revise(user, { raw: "Editing post to fake include a mention of @eviltrout" }, revised_at: Time.now)

      events = DiscourseEvent.track_events do
        PostAlerter.new.create_notification(user, Notification.types[:mentioned], post)
      end

      payload = {
       notification_type: type,
       post_number: post.post_number,
       topic_title: post.topic.title,
       topic_id: post.topic.id,
       excerpt: post.excerpt(400, text_entities: true, strip_links: true, remap_emoji: true),
       username: post.username,
       post_url: post.url
      }

      expect(events).not_to include(event_name: :pre_notification_alert, params: [user, payload])
    end

    it "triggers :before_create_notification" do
      type = Notification.types[:private_message]
      events = DiscourseEvent.track_events do
        PostAlerter.new.create_notification(user, type, post, {})
      end
      expect(events).to include(event_name: :before_create_notification, params: [user, type, post, {}])
    end
  end

  describe "push_notification" do
    let(:mention_post) { create_post_with_alerts(user: user, raw: 'Hello @eviltrout :heart:') }
    let(:topic) { mention_post.topic }

    it "pushes nothing to suspended users" do
      SiteSetting.allowed_user_api_push_urls = "https://site.com/push|https://site2.com/push"

      evil_trout.update_columns(suspended_till: 1.year.from_now)

      2.times do |i|
        UserApiKey.create!(user_id: evil_trout.id,
                           client_id: "xxx#{i}",
                           key: "yyy#{i}",
                           application_name: "iPhone#{i}",
                           scopes: ['notifications'],
                           push_url: "https://site2.com/push")
      end

      expect { mention_post }.to_not change { Jobs::PushNotification.jobs.count }
    end

    it "correctly pushes notifications if configured correctly" do
      Jobs.run_immediately!
      SiteSetting.allowed_user_api_push_urls = "https://site.com/push|https://site2.com/push"

      2.times do |i|
        UserApiKey.create!(user_id: evil_trout.id,
                           client_id: "xxx#{i}",
                           key: "yyy#{i}",
                           application_name: "iPhone#{i}",
                           scopes: ['notifications'],
                           push_url: "https://site2.com/push")
      end

      body = nil
      headers = nil

      stub_request(:post, "https://site2.com/push")
        .to_return do |request|
          body = request.body
          headers = request.headers
          { status: 200, body: "OK" }
        end

      payload = {
        "secret_key" => SiteSetting.push_api_secret_key,
        "url" => Discourse.base_url,
        "title" => SiteSetting.title,
        "description" => SiteSetting.site_description,
        "notifications" => [
        {
          'notification_type' => 1,
          'post_number' => 1,
          'topic_title' => topic.title,
          'topic_id' => topic.id,
          'excerpt' => 'Hello @eviltrout ❤',
          'username' => user.username,
          'url' => UrlHelper.absolute(mention_post.url),
          'client_id' => 'xxx0'
        },
        {
          'notification_type' => 1,
          'post_number' => 1,
          'topic_title' => topic.title,
          'topic_id' => topic.id,
          'excerpt' => 'Hello @eviltrout ❤',
          'username' => user.username,
          'url' => UrlHelper.absolute(mention_post.url),
          'client_id' => 'xxx1'
        }
        ]
      }

      post = mention_post

      expect(JSON.parse(body)).to eq(payload)
      expect(headers["Content-Type"]).to eq('application/json')

      TopicUser.change(evil_trout.id, topic.id, notification_level: TopicUser.notification_levels[:watching])

      post = Fabricate(:post, topic: post.topic, user_id: evil_trout.id)
      user2 = Fabricate(:user)

      # if we collapse a reply notification we should get notified on the correct post
      new_post = create_post_with_alerts(topic: post.topic, user_id: user.id, reply_to_post_number: post.post_number, raw: 'this is my first reply')

      changes = {
        "notification_type" => Notification.types[:posted],
        "post_number" => new_post.post_number,
        "username" => new_post.user.username,
        "excerpt" => new_post.raw,
        "url" => UrlHelper.absolute(new_post.url)
      }

      payload["notifications"][0].merge! changes
      payload["notifications"][1].merge! changes

      expect(JSON.parse(body)).to eq(payload)

      new_post = create_post_with_alerts(topic: post.topic, user_id: user2.id, reply_to_post_number: post.post_number, raw: 'this is my second reply')

      changes = {
        "post_number" => new_post.post_number,
        "username" => new_post.user.username,
        "excerpt" => new_post.raw,
        "url" => UrlHelper.absolute(new_post.url)
      }

      payload["notifications"][0].merge! changes
      payload["notifications"][1].merge! changes

      expect(JSON.parse(body)).to eq(payload)

    end
  end

  describe "watching_first_post" do
    fab!(:group) { Fabricate(:group) }
    fab!(:user) { Fabricate(:user) }
    fab!(:category) { Fabricate(:category) }
    fab!(:tag)  { Fabricate(:tag) }
    fab!(:topic) { Fabricate(:topic, category: category, tags: [tag]) }
    fab!(:post) { Fabricate(:post, topic: topic) }

    it "doesn't notify people who aren't watching" do
      PostAlerter.post_created(post)
      expect(user.notifications.where(notification_type: Notification.types[:watching_first_post]).count).to eq(0)
    end

    it "notifies the user who is following the first post category" do
      level = CategoryUser.notification_levels[:watching_first_post]
      CategoryUser.set_notification_level_for_category(user, level, category.id)
      PostAlerter.new.after_save_post(post, true)
      expect(user.notifications.where(notification_type: Notification.types[:watching_first_post]).count).to eq(1)
    end

    it "doesn't notify when the record is not new" do
      level = CategoryUser.notification_levels[:watching_first_post]
      CategoryUser.set_notification_level_for_category(user, level, category.id)
      PostAlerter.new.after_save_post(post, false)
      expect(user.notifications.where(notification_type: Notification.types[:watching_first_post]).count).to eq(0)
    end

    it "notifies the user who is following the first post tag" do
      level = TagUser.notification_levels[:watching_first_post]
      TagUser.change(user.id, tag.id, level)
      PostAlerter.post_created(post)
      expect(user.notifications.where(notification_type: Notification.types[:watching_first_post]).count).to eq(1)
    end

    it "notifies the user who is following the first post group" do
      GroupUser.create(group_id: group.id, user_id: user.id)
      GroupUser.create(group_id: group.id, user_id: post.user.id)
      topic.topic_allowed_groups.create(group_id: group.id)

      level = GroupUser.notification_levels[:watching_first_post]
      GroupUser.where(user_id: user.id, group_id: group.id).update_all(notification_level: level)

      PostAlerter.post_created(post)
      expect(user.notifications.where(notification_type: Notification.types[:watching_first_post]).count).to eq(1)
    end

    it "triggers :before_create_notifications_for_users" do
      level = CategoryUser.notification_levels[:watching_first_post]
      CategoryUser.set_notification_level_for_category(user, level, category.id)
      events = DiscourseEvent.track_events do
        PostAlerter.new.after_save_post(post, true)
      end
      expect(events).to include(event_name: :before_create_notifications_for_users, params: [[user], post])
    end
  end

  context "replies" do
    it "triggers :before_create_notifications_for_users" do
      user = Fabricate(:user)
      topic = Fabricate(:topic)
      _post = Fabricate(:post, user: user, topic: topic)
      reply = Fabricate(:post, topic: topic, reply_to_post_number: 1)
      events = DiscourseEvent.track_events do
        PostAlerter.post_created(reply)
      end
      expect(events).to include(event_name: :before_create_notifications_for_users, params: [[user], reply])
    end

    it "notifies about regular reply" do
      user = Fabricate(:user)
      topic = Fabricate(:topic)
      _post = Fabricate(:post, user: user, topic: topic)

      reply = Fabricate(:post, topic: topic, reply_to_post_number: 1)
      PostAlerter.post_created(reply)

      expect(user.notifications.where(notification_type: Notification.types[:replied]).count).to eq(1)
    end

    it "doesn't notify regular user about whispered reply" do
      user = Fabricate(:user)
      admin = Fabricate(:admin)

      topic = Fabricate(:topic)
      _post = Fabricate(:post, user: user, topic: topic)

      whispered_reply = Fabricate(:post, user: admin, topic: topic, post_type: Post.types[:whisper], reply_to_post_number: 1)
      PostAlerter.post_created(whispered_reply)

      expect(user.notifications.where(notification_type: Notification.types[:replied]).count).to eq(0)
    end

    it "notifies staff user about whispered reply" do
      user = Fabricate(:user)
      admin1 = Fabricate(:admin)
      admin2 = Fabricate(:admin)

      topic = Fabricate(:topic)
      _post = Fabricate(:post, user: user, topic: topic)

      whispered_reply1 = Fabricate(:post, user: admin1, topic: topic, post_type: Post.types[:whisper], reply_to_post_number: 1)
      whispered_reply2 = Fabricate(:post, user: admin2, topic: topic, post_type: Post.types[:whisper], reply_to_post_number: 2)
      PostAlerter.post_created(whispered_reply1)
      PostAlerter.post_created(whispered_reply2)

      expect(admin1.notifications.where(notification_type: Notification.types[:replied]).count).to eq(1)

      TopicUser.change(admin1.id, topic.id, notification_level: TopicUser.notification_levels[:watching])

      # this should change nothing cause the moderator post has an action code
      # if we have an action code then we should never have notifications, this is rare but
      # assign whispers are like this
      whispered_reply3 = topic.add_moderator_post(admin2, "i am a reply", post_type: Post.types[:whisper], action_code: 'moderator_thing')
      PostAlerter.post_created(whispered_reply3)

      # if this whisper is not ignored like it should we would see a posted notification and no replied notifications
      notifications = admin1.notifications.where(topic_id: topic.id).to_a

      expect(notifications.first.notification_type).to eq(Notification.types[:replied])
      expect(notifications.length).to eq(1)
      expect(notifications.first.post_number).to eq(whispered_reply2.post_number)
    end

    it "sends email notifications only to users not on CC list of incoming email" do
      alice = Fabricate(:user, username: "alice", email: "alice@example.com")
      bob = Fabricate(:user, username: "bob", email: "bob@example.com")
      carol = Fabricate(:user, username: "carol", email: "carol@example.com", staged: true)
      dave = Fabricate(:user, username: "dave", email: "dave@example.com", staged: true)
      erin = Fabricate(:user, username: "erin", email: "erin@example.com")

      topic = Fabricate(:private_message_topic, topic_allowed_users: [
        Fabricate.build(:topic_allowed_user, user: alice),
        Fabricate.build(:topic_allowed_user, user: bob),
        Fabricate.build(:topic_allowed_user, user: carol),
        Fabricate.build(:topic_allowed_user, user: dave),
        Fabricate.build(:topic_allowed_user, user: erin)
      ])
      _post = Fabricate(:post, user: alice, topic: topic)

      TopicUser.change(alice.id, topic.id, notification_level: TopicUser.notification_levels[:watching])
      TopicUser.change(bob.id, topic.id, notification_level: TopicUser.notification_levels[:watching])
      TopicUser.change(erin.id, topic.id, notification_level: TopicUser.notification_levels[:watching])

      email = Fabricate(:incoming_email,
                        raw: <<~RAW,
                          Return-Path: <bob@example.com>
                          From: Bob <bob@example.com>
                          To: meta+1234@discoursemail.com, dave@example.com
                          CC: carol@example.com, erin@example.com
                          Subject: Hello world
                          Date: Fri, 15 Jan 2016 00:12:43 +0100
                          Message-ID: <12345@example.com>
                          Mime-Version: 1.0
                          Content-Type: text/plain; charset=UTF-8
                          Content-Transfer-Encoding: quoted-printable

                          This post was created by email.
                        RAW
                        from_address: "bob@example.com",
                        to_addresses: "meta+1234@discoursemail.com;dave@example.com",
                        cc_addresses: "carol@example.com;erin@example.com")
      reply = Fabricate(:post_via_email, user: bob, topic: topic, incoming_email: email, reply_to_post_number: 1)

      NotificationEmailer.expects(:process_notification).with { |n| n.user_id == alice.id }.once
      NotificationEmailer.expects(:process_notification).with { |n| n.user_id == bob.id }.never
      NotificationEmailer.expects(:process_notification).with { |n| n.user_id == carol.id }.never
      NotificationEmailer.expects(:process_notification).with { |n| n.user_id == dave.id }.never
      NotificationEmailer.expects(:process_notification).with { |n| n.user_id == erin.id }.never

      PostAlerter.post_created(reply)

      expect(alice.notifications.count).to eq(1)
      expect(bob.notifications.count).to eq(0)
      expect(carol.notifications.count).to eq(1)
      expect(dave.notifications.count).to eq(1)
      expect(erin.notifications.count).to eq(1)
    end

    it "does not send email notifications to staged users when notification originates in mailinglist mirror category" do
      category = Fabricate(:mailinglist_mirror_category)
      topic = Fabricate(:topic, category: category)
      user = Fabricate(:staged)
      _post = Fabricate(:post, user: user, topic: topic)
      reply = Fabricate(:post, topic: topic, reply_to_post_number: 1)

      NotificationEmailer.expects(:process_notification).never
      expect { PostAlerter.post_created(reply) }.to change(user.notifications, :count).by(0)

      category.mailinglist_mirror = false
      NotificationEmailer.expects(:process_notification).once
      expect { PostAlerter.post_created(reply) }.to change(user.notifications, :count).by(1)
    end
  end

  context "category" do
    context "watching" do
      it "triggers :before_create_notifications_for_users" do
        user = Fabricate(:user)
        category = Fabricate(:category)
        topic = Fabricate(:topic, category: category)
        post = Fabricate(:post, topic: topic)
        level = CategoryUser.notification_levels[:watching]
        CategoryUser.set_notification_level_for_category(user, level, category.id)
        events = DiscourseEvent.track_events do
          PostAlerter.post_created(post)
        end
        expect(events).to include(event_name: :before_create_notifications_for_users, params: [[user], post])
      end

      it "notifies staff about whispered post" do
        category = Fabricate(:category)
        topic = Fabricate(:topic, category: category)
        admin = Fabricate(:admin)
        user = Fabricate(:user)
        level = CategoryUser.notification_levels[:watching]
        CategoryUser.set_notification_level_for_category(admin, level, category.id)
        CategoryUser.set_notification_level_for_category(user, level, category.id)
        whispered_post = Fabricate(:post, user: Fabricate(:admin), topic: topic, post_type: Post.types[:whisper])
        expect {
          PostAlerter.post_created(whispered_post)
        }.to add_notification(admin, :posted)
        expect {
          PostAlerter.post_created(whispered_post)
        }.not_to add_notification(user, :posted)
      end

      it "notifies a staged user about a private post, but only if the user has access" do
        staged_member = Fabricate(:staged)
        staged_non_member = Fabricate(:staged)
        group = Fabricate(:group)
        group_member = Fabricate(:user)

        group.add(group_member)
        group.add(staged_member)

        private_category = Fabricate(
          :private_category, group: group,
                             email_in: 'test@test.com', email_in_allow_strangers: false
        )

        level = CategoryUser.notification_levels[:watching]
        CategoryUser.set_notification_level_for_category(group_member, level, private_category.id)
        CategoryUser.set_notification_level_for_category(staged_member, level, private_category.id)
        CategoryUser.set_notification_level_for_category(staged_non_member, level, private_category.id)

        topic = Fabricate(:topic, category: private_category, user: group_member)
        post = Fabricate(:post, topic: topic)

        expect {
          PostAlerter.post_created(post)
        }.to add_notification(staged_member, :posted)
          .and not_add_notification(staged_non_member, :posted)
      end
    end
  end

  context "tags" do
    context "watching" do
      it "triggers :before_create_notifications_for_users" do
        user = Fabricate(:user)
        tag = Fabricate(:tag)
        topic = Fabricate(:topic, tags: [tag])
        post = Fabricate(:post, topic: topic)
        level = TagUser.notification_levels[:watching]
        TagUser.change(user.id, tag.id, level)
        events = DiscourseEvent.track_events do
          PostAlerter.post_created(post)
        end
        expect(events).to include(event_name: :before_create_notifications_for_users, params: [[user], post])
      end
    end

    context "on change" do
      fab!(:user) { Fabricate(:user) }
      fab!(:other_tag) { Fabricate(:tag) }
      fab!(:watched_tag) { Fabricate(:tag) }
      fab!(:post) { Fabricate(:post) }

      before do
        SiteSetting.tagging_enabled = true
        Jobs.run_immediately!
        TagUser.change(user.id, watched_tag.id, TagUser.notification_levels[:watching_first_post])
        TopicUser.change(Fabricate(:user).id, post.topic.id, notification_level: TopicUser.notification_levels[:watching])
      end

      it "triggers a notification" do
        expect(user.notifications.where(notification_type: Notification.types[:watching_first_post]).count).to eq(0)

        expect { PostRevisor.new(post).revise!(Fabricate(:user), tags: [other_tag.name, watched_tag.name]) }.to change { Notification.where(user_id: user.id).count }.by(1)
        expect(user.notifications.where(notification_type: Notification.types[:watching_first_post]).count).to eq(1)

        expect { PostRevisor.new(post).revise!(Fabricate(:user), tags: [watched_tag.name, other_tag.name]) }.to change { Notification.count }.by(0)
        expect(user.notifications.where(notification_type: Notification.types[:watching_first_post]).count).to eq(1)
      end

      it "doesn't trigger a notification if topic is unlisted" do
        post.topic.update_column(:visible, false)

        expect(user.notifications.where(notification_type: Notification.types[:watching_first_post]).count).to eq(0)

        PostRevisor.new(post).revise!(Fabricate(:user), tags: [other_tag.name, watched_tag.name])
        expect(user.notifications.where(notification_type: Notification.types[:watching_first_post]).count).to eq(0)
      end
    end
  end

  describe '#extract_linked_users' do
    fab!(:topic) { Fabricate(:topic) }
    fab!(:post) { Fabricate(:post, topic: topic) }
    fab!(:post2) { Fabricate(:post) }

    describe 'when linked post has been deleted' do
      let(:topic_link) do
        TopicLink.create!(
          url: "/t/#{topic.id}",
          topic_id: topic.id,
          link_topic_id: post2.topic.id,
          link_post_id: nil,
          post_id: post.id,
          user: user,
          domain: 'test.com'
        )
      end

      it 'should use the first post of the topic' do
        topic_link
        expect(PostAlerter.new.extract_linked_users(post.reload)).to eq([post2.user])
      end
    end
  end

  describe '#notify_post_users' do
    fab!(:topic) { Fabricate(:topic) }
    fab!(:post) { Fabricate(:post, topic: topic) }

    it 'creates single edit notification when post is modified' do
      TopicUser.create!(user_id: user.id, topic_id: topic.id, notification_level: TopicUser.notification_levels[:watching], highest_seen_post_number: post.post_number)
      PostAlerter.new.notify_post_users(post, [])
      expect(Notification.count).to eq(1)
      expect(Notification.last.notification_type).to eq(Notification.types[:edited])

      PostAlerter.new.notify_post_users(post, [])
      expect(Notification.count).to eq(1)
    end
  end
end

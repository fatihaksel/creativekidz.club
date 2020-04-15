# frozen_string_literal: true

require 'rails_helper'

describe TopicTrackingState do

  fab!(:user) do
    Fabricate(:user)
  end

  let(:post) do
    create_post
  end

  let(:topic) { post.topic }
  fab!(:private_message_post) { Fabricate(:private_message_post) }
  let(:private_message_topic) { private_message_post.topic }

  describe '#publish_latest' do
    it 'can correctly publish latest' do
      message = MessageBus.track_publish("/latest") do
        described_class.publish_latest(topic)
      end.first

      data = message.data

      expect(data["topic_id"]).to eq(topic.id)
      expect(data["message_type"]).to eq(described_class::LATEST_MESSAGE_TYPE)
      expect(data["payload"]["archetype"]).to eq(Archetype.default)
    end

    describe 'private message' do
      it 'should not publish any message' do
        messages = MessageBus.track_publish do
          described_class.publish_latest(private_message_topic)
        end

        expect(messages).to eq([])
      end
    end
  end

  describe '#publish_unread' do
    it "can correctly publish unread" do
      message = MessageBus.track_publish(described_class.unread_channel_key(post.user.id)) do
        TopicTrackingState.publish_unread(post)
      end.first

      data = message.data

      expect(data["topic_id"]).to eq(topic.id)
      expect(data["message_type"]).to eq(described_class::UNREAD_MESSAGE_TYPE)
      expect(data["payload"]["archetype"]).to eq(Archetype.default)
    end

    describe 'for a private message' do
      before do
        TopicUser.change(
          private_message_topic.allowed_users.first.id,
          private_message_topic.id,
          notification_level: TopicUser.notification_levels[:tracking]
        )
      end

      it 'should not publish any message' do
        messages = MessageBus.track_publish do
          TopicTrackingState.publish_unread(private_message_post)
        end

        expect(messages).to eq([])
      end
    end
  end

  describe '#publish_private_message' do
    fab!(:admin) { Fabricate(:admin) }

    describe 'normal topic' do
      it 'should publish the right message' do
        allowed_users = private_message_topic.allowed_users

        messages = MessageBus.track_publish do
          TopicTrackingState.publish_private_message(private_message_topic)
        end

        expect(messages.count).to eq(1)

        message = messages.first

        expect(message.channel).to eq('/private-messages/inbox')
        expect(message.data["topic_id"]).to eq(private_message_topic.id)
        expect(message.user_ids).to contain_exactly(*allowed_users.map(&:id))
      end
    end

    describe 'topic with groups' do
      fab!(:group1) { Fabricate(:group, users: [Fabricate(:user)]) }
      fab!(:group2) { Fabricate(:group, users: [Fabricate(:user), Fabricate(:user)]) }

      before do
        [group1, group2].each do |group|
          private_message_topic.allowed_groups << group
        end
      end

      it "should publish the right message" do
        messages = MessageBus.track_publish do
          TopicTrackingState.publish_private_message(
            private_message_topic
          )
        end

        expect(messages.map(&:channel)).to contain_exactly(
          '/private-messages/inbox',
          "/private-messages/group/#{group1.name}",
          "/private-messages/group/#{group2.name}"
        )

        message = messages.find do |m|
          m.channel == '/private-messages/inbox'
        end

        expect(message.data["topic_id"]).to eq(private_message_topic.id)
        expect(message.user_ids).to eq(private_message_topic.allowed_users.map(&:id))

        [group1, group2].each do |group|
          message = messages.find do |m|
            m.channel == "/private-messages/group/#{group.name}"
          end

          expect(message.data["topic_id"]).to eq(private_message_topic.id)
          expect(message.user_ids).to eq(group.users.map(&:id))
        end
      end

      describe "archiving topic" do
        it "should publish the right message" do
          messages = MessageBus.track_publish do
            TopicTrackingState.publish_private_message(
              private_message_topic,
              group_archive: true
            )
          end

          expect(messages.map(&:channel)).to contain_exactly(
            '/private-messages/inbox',
            "/private-messages/group/#{group1.name}",
            "/private-messages/group/#{group1.name}/archive",
            "/private-messages/group/#{group2.name}",
            "/private-messages/group/#{group2.name}/archive",
          )

          message = messages.find { |m| m.channel == '/private-messages/inbox' }

          expect(message.data["topic_id"]).to eq(private_message_topic.id)
          expect(message.user_ids).to eq(private_message_topic.allowed_users.map(&:id))

          [group1, group2].each do |group|
            group_channel = "/private-messages/group/#{group.name}"

            [
              group_channel,
              "#{group_channel}/archive"
            ].each do |channel|
              message = messages.find { |m| m.channel == channel }
              expect(message.data["topic_id"]).to eq(private_message_topic.id)
              expect(message.user_ids).to eq(group.users.map(&:id))
            end
          end
        end
      end
    end

    describe 'topic with new post' do
      let(:user) { private_message_topic.allowed_users.last }

      let!(:post) do
        Fabricate(:post,
          topic: private_message_topic,
          user: user
        )
      end

      let!(:group) do
        group = Fabricate(:group, users: [Fabricate(:user)])
        private_message_topic.allowed_groups << group
        group
      end

      it 'should publish the right message' do
        messages = MessageBus.track_publish do
          TopicTrackingState.publish_private_message(
            private_message_topic,
            post: post
          )
        end

        expected_channels = [
          '/private-messages/inbox',
          '/private-messages/sent',
          "/private-messages/group/#{group.name}"
        ]

        expect(messages.map(&:channel)).to contain_exactly(*expected_channels)

        expected_channels.zip([
          private_message_topic.allowed_users.map(&:id),
          [user.id],
          [group.users.first.id]
        ]).each do |channel, user_ids|
          message = messages.find { |m| m.channel == channel }

          expect(message.data["topic_id"]).to eq(private_message_topic.id)
          expect(message.user_ids).to eq(user_ids)
        end
      end
    end

    describe 'archived topic' do
      it 'should publish the right message' do
        messages = MessageBus.track_publish do
          TopicTrackingState.publish_private_message(
            private_message_topic,
            archive_user_id: private_message_post.user_id,
          )
        end

        expected_channels = [
          "/private-messages/archive",
          "/private-messages/inbox",
          "/private-messages/sent",
        ]

        expect(messages.map(&:channel)).to eq(expected_channels)

        expected_channels.each do |channel|
          message = messages.find { |m| m.channel = channel }
          expect(message.data["topic_id"]).to eq(private_message_topic.id)
          expect(message.user_ids).to eq([private_message_post.user_id])
        end
      end
    end

    describe 'for a regular topic' do
      it 'should not publish any message' do
        topic.allowed_users << Fabricate(:user)

        messages = MessageBus.track_publish do
          TopicTrackingState.publish_private_message(topic)
        end

        expect(messages).to eq([])
      end
    end
  end

  describe '#publish_read_private_message' do
    fab!(:group) { Fabricate(:group) }
    let(:read_topic_key) { "/private-messages/unread-indicator/#{@group_message.id}" }
    let(:read_post_key) { "/topic/#{@group_message.id}" }
    let(:latest_post_number) { 3 }

    before do
      group.add(user)
      @group_message = Fabricate(:private_message_topic,
        allowed_groups: [group],
        topic_allowed_users: [Fabricate.build(:topic_allowed_user, user: user)],
        highest_post_number: latest_post_number
      )
      @post = Fabricate(:post, topic: @group_message, post_number: latest_post_number)
    end

    it 'does not trigger a read count update if no allowed groups have the option enabled' do
      messages = MessageBus.track_publish(read_post_key) do
        TopicTrackingState.publish_read_indicator_on_read(@group_message.id, latest_post_number, user.id)
      end

      expect(messages).to be_empty
    end

    context 'when the read indicator is enabled' do
      before { group.update!(publish_read_state: true) }

      it 'publishes a message to hide the unread indicator' do
        message = MessageBus.track_publish(read_topic_key) do
          TopicTrackingState.publish_read_indicator_on_read(@group_message.id, latest_post_number, user.id)
        end.first

        expect(message.data['topic_id']).to eq @group_message.id
        expect(message.data['show_indicator']).to eq false
      end

      it 'publishes a message to show the unread indicator when a non-member creates a new post' do
        allowed_user = Fabricate(:topic_allowed_user, topic: @group_message)
        message = MessageBus.track_publish(read_topic_key) do
          TopicTrackingState.publish_read_indicator_on_write(@group_message.id, latest_post_number, allowed_user.id)
        end.first

        expect(message.data['topic_id']).to eq @group_message.id
        expect(message.data['show_indicator']).to eq true
      end

      it 'does not publish the unread indicator if the message is not the last one' do
        not_last_post_number = latest_post_number - 1
        Fabricate(:post, topic: @group_message, post_number: not_last_post_number)
        messages = MessageBus.track_publish(read_topic_key) do
          TopicTrackingState.publish_read_indicator_on_read(@group_message.id, not_last_post_number, user.id)
        end

        expect(messages).to be_empty
      end

      it 'does not publish the read indicator if the user is not a group member' do
        allowed_user = Fabricate(:topic_allowed_user, topic: @group_message)
        messages = MessageBus.track_publish(read_topic_key) do
          TopicTrackingState.publish_read_indicator_on_read(@group_message.id, latest_post_number, allowed_user.user_id)
        end

        expect(messages).to be_empty
      end

      it 'publish a read count update to every client' do
        message = MessageBus.track_publish(read_post_key) do
          TopicTrackingState.publish_read_indicator_on_read(@group_message.id, latest_post_number, user.id)
        end.first

        expect(message.data[:type]).to eq :read
      end
    end
  end

  it "correctly handles muted categories" do

    user = Fabricate(:user)
    post

    report = TopicTrackingState.report(user)
    expect(report.length).to eq(1)

    CategoryUser.create!(user_id: user.id,
                         notification_level: CategoryUser.notification_levels[:muted],
                         category_id: post.topic.category_id
                         )

    create_post(topic_id: post.topic_id)

    report = TopicTrackingState.report(user)
    expect(report.length).to eq(0)

    TopicUser.create!(user_id: user.id, topic_id: post.topic_id, last_read_post_number: 1, notification_level: 3)

    report = TopicTrackingState.report(user)
    expect(report.length).to eq(1)
  end

  it "correctly handles category_users with null notification level" do
    user = Fabricate(:user)
    post

    report = TopicTrackingState.report(user)
    expect(report.length).to eq(1)

    CategoryUser.create!(user_id: user.id, category_id: post.topic.category_id)

    report = TopicTrackingState.report(user)
    expect(report.length).to eq(1)
  end

  it "works when categories are default muted" do
    SiteSetting.mute_all_categories_by_default = true

    user = Fabricate(:user)
    post

    report = TopicTrackingState.report(user)
    expect(report.length).to eq(0)

    CategoryUser.create!(user_id: user.id,
                         notification_level: CategoryUser.notification_levels[:regular],
                         category_id: post.topic.category_id
                         )

    create_post(topic_id: post.topic_id)

    report = TopicTrackingState.report(user)
    expect(report.length).to eq(1)
  end

  context 'muted tags' do
    it "remove_muted_tags_from_latest is set to always" do
      SiteSetting.remove_muted_tags_from_latest = 'always'
      user = Fabricate(:user)
      tag1 = Fabricate(:tag)
      tag2 = Fabricate(:tag)
      Fabricate(:topic_tag, tag: tag1, topic: topic)
      Fabricate(:topic_tag, tag: tag2, topic: topic)
      post

      report = TopicTrackingState.report(user)
      expect(report.length).to eq(1)

      TagUser.create!(user_id: user.id,
                      notification_level: TagUser.notification_levels[:muted],
                      tag_id: tag1.id
                     )

      report = TopicTrackingState.report(user)
      expect(report.length).to eq(0)
    end

    it "remove_muted_tags_from_latest is set to only_muted" do
      SiteSetting.remove_muted_tags_from_latest = 'only_muted'
      user = Fabricate(:user)
      tag1 = Fabricate(:tag)
      tag2 = Fabricate(:tag)
      Fabricate(:topic_tag, tag: tag1, topic: topic)
      Fabricate(:topic_tag, tag: tag2, topic: topic)
      post

      report = TopicTrackingState.report(user)
      expect(report.length).to eq(1)

      TagUser.create!(user_id: user.id,
                      notification_level: TagUser.notification_levels[:muted],
                      tag_id: tag1.id
                     )

      report = TopicTrackingState.report(user)
      expect(report.length).to eq(1)

      TagUser.create!(user_id: user.id,
                      notification_level: TagUser.notification_levels[:muted],
                      tag_id: tag2.id
                     )

      report = TopicTrackingState.report(user)
      expect(report.length).to eq(0)
    end

    it "remove_muted_tags_from_latest is set to never" do
      SiteSetting.remove_muted_tags_from_latest = 'never'
      user = Fabricate(:user)
      tag1 = Fabricate(:tag)
      Fabricate(:topic_tag, tag: tag1, topic: topic)
      post

      report = TopicTrackingState.report(user)
      expect(report.length).to eq(1)

      TagUser.create!(user_id: user.id,
                      notification_level: TagUser.notification_levels[:muted],
                      tag_id: tag1.id
                     )

      report = TopicTrackingState.report(user)
      expect(report.length).to eq(1)
    end
  end

  it "correctly handles seen categories" do
    freeze_time 1.minute.ago
    user = Fabricate(:user)
    post

    report = TopicTrackingState.report(user)
    expect(report.length).to eq(1)

    CategoryUser.create!(user_id: user.id,
                         notification_level: CategoryUser.notification_levels[:regular],
                         category_id: post.topic.category_id,
                         last_seen_at: post.topic.created_at
                         )

    report = TopicTrackingState.report(user)
    expect(report.length).to eq(0)

    unfreeze_time
    post.topic.touch(:created_at)

    report = TopicTrackingState.report(user)
    expect(report.length).to eq(1)
  end

  it "correctly handles capping" do
    user = Fabricate(:user)

    post1 = create_post
    Fabricate(:post, topic: post1.topic)

    post2 = create_post
    Fabricate(:post, topic: post2.topic)

    post3 = create_post
    Fabricate(:post, topic: post3.topic)

    tracking = {
      notification_level: TopicUser.notification_levels[:tracking],
      last_read_post_number: 1,
      highest_seen_post_number: 1
    }

    TopicUser.change(user.id, post1.topic_id, tracking)
    TopicUser.change(user.id, post2.topic_id, tracking)
    TopicUser.change(user.id, post3.topic_id, tracking)

    report = TopicTrackingState.report(user)
    expect(report.length).to eq(3)

  end

  it "correctly gets the tracking state" do
    report = TopicTrackingState.report(user)
    expect(report.length).to eq(0)

    post.topic.notifier.watch_topic!(post.topic.user_id)

    report = TopicTrackingState.report(user)

    expect(report.length).to eq(1)
    row = report[0]

    expect(row.topic_id).to eq(post.topic_id)
    expect(row.highest_post_number).to eq(1)
    expect(row.last_read_post_number).to eq(nil)
    expect(row.user_id).to eq(user.id)

    # lets not leak out random users
    expect(TopicTrackingState.report(post.user)).to be_empty

    # lets not return anything if we scope on non-existing topic
    expect(TopicTrackingState.report(user, post.topic_id + 1)).to be_empty

    # when we reply the poster should have an unread row
    create_post(user: user, topic: post.topic)

    report = TopicTrackingState.report(user)
    expect(report.length).to eq(0)

    report = TopicTrackingState.report(post.user)
    expect(report.length).to eq(1)

    row = report[0]

    expect(row.topic_id).to eq(post.topic_id)
    expect(row.highest_post_number).to eq(2)
    expect(row.last_read_post_number).to eq(1)
    expect(row.user_id).to eq(post.user_id)

    # when we have no permission to see a category, don't show its stats
    category = Fabricate(:category, read_restricted: true)

    post.topic.category_id = category.id
    post.topic.save

    expect(TopicTrackingState.report(post.user)).to be_empty
    expect(TopicTrackingState.report(user)).to be_empty
  end
end

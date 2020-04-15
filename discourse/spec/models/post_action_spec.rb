# frozen_string_literal: true

require 'rails_helper'

describe PostAction do
  it { is_expected.to rate_limit }

  fab!(:moderator) { Fabricate(:moderator) }
  fab!(:codinghorror) { Fabricate(:coding_horror) }
  fab!(:eviltrout) { Fabricate(:evil_trout) }
  fab!(:admin) { Fabricate(:admin) }
  fab!(:post) { Fabricate(:post) }
  fab!(:second_post) { Fabricate(:post, topic: post.topic) }
  let(:bookmark) { PostAction.new(user_id: post.user_id, post_action_type_id: PostActionType.types[:bookmark] , post_id: post.id) }

  def value_for(user_id, dt)
    GivenDailyLike.find_for(user_id, dt).pluck(:likes_given)[0] || 0
  end

  it "disallows the same action from happening twice" do
    PostAction.create(user: eviltrout, post: post, post_action_type_id: PostActionType.types[:like])
    pa = PostAction.new(user: eviltrout, post: post, post_action_type_id: PostActionType.types[:like])
    expect(pa).not_to be_valid
  end

  context "messaging" do

    it "notifies moderators (integration test)" do
      post = create_post
      mod = moderator
      Group.refresh_automatic_groups!

      result = PostActionCreator.notify_moderators(
        codinghorror,
        post,
        "this is my special long message"
      )

      posts = Post.joins(:topic)
        .select('posts.id, topics.subtype, posts.topic_id')
        .where('topics.archetype' => Archetype.private_message)
        .to_a

      expect(posts.count).to eq(1)
      expect(result.post_action.related_post_id).to eq(posts[0].id.to_i)
      expect(result.reviewable_score.meta_topic_id).to eq(posts[0].topic_id)
      expect(posts[0].subtype).to eq(TopicSubtype.notify_moderators)

      topic = posts[0].topic

      # Moderators should be invited to the private topic, otherwise they're not permitted to see it
      topic_user_ids = topic.reload.topic_users.map { |x| x.user_id }
      expect(topic_user_ids).to include(codinghorror.id)
      expect(topic_user_ids).to include(mod.id)

      expect(topic.topic_users.where(user_id: mod.id)
              .pluck_first(:notification_level)).to eq(TopicUser.notification_levels[:tracking])

      expect(topic.topic_users.where(user_id: codinghorror.id)
              .pluck_first(:notification_level)).to eq(TopicUser.notification_levels[:watching])

      # reply to PM should not clear flag
      PostCreator.new(mod, topic_id: posts[0].topic_id, raw: "This is my test reply to the user, it should clear flags").create
      result.post_action.reload
      expect(result.post_action.deleted_at).to eq(nil)

      # Acting on the flag should not post an automated status message (since a moderator already replied)
      expect(topic.posts.count).to eq(2)

      result.reviewable.perform(admin, :agree_and_keep)
      topic.reload
      expect(topic.posts.count).to eq(2)

      # Clearing the flags should not post an automated status message
      result = PostActionCreator.notify_moderators(mod, post, "another special message")
      result.reviewable.perform(admin, :disagree)
      topic.reload
      expect(topic.posts.count).to eq(2)

      # Acting on the flag should post an automated status message
      another_post = create_post
      result = PostActionCreator.notify_moderators(codinghorror, another_post, "foobar")
      topic = result.post_action.related_post.topic

      expect(topic.posts.count).to eq(1)
      result.reviewable.perform(admin, :agree_and_keep)

      topic.reload
      expect(topic.posts.count).to eq(2)
      expect(topic.posts.last.post_type).to eq(Post.types[:moderator_action])
    end

  end

  describe "update_counters" do
    it "properly updates topic counters" do
      freeze_time Date.today
      # we need this to test it
      TopicUser.change(codinghorror, post.topic, posted: true)

      expect(value_for(moderator.id, Date.today)).to eq(0)

      PostActionCreator.like(moderator, post)
      PostActionCreator.like(codinghorror, second_post)

      post.topic.reload
      expect(post.topic.like_count).to eq(2)

      expect(value_for(moderator.id, Date.today)).to eq(1)

      tu = TopicUser.get(post.topic, codinghorror)
      expect(tu.liked).to be true
      expect(tu.bookmarked).to be false
    end

  end

  describe "when a user bookmarks something" do
    it "increases the post's bookmark count when saved" do
      expect { bookmark.save; post.reload }.to change(post, :bookmark_count).by(1)
    end

    describe 'when deleted' do

      before do
        bookmark.save
        post.reload
        @topic = post.topic
        @topic.reload
        bookmark.deleted_at = DateTime.now
        bookmark.save
      end

      it 'reduces the bookmark count of the post' do
        expect { post.reload }.to change(post, :bookmark_count).by(-1)
      end

    end
  end

  describe "undo/redo repeatedly" do
    it "doesn't create a second action for the same user/type" do
      PostActionCreator.like(codinghorror, post)
      PostActionDestroyer.destroy(codinghorror, post, :like)
      PostActionCreator.like(codinghorror, post)
      expect(PostAction.where(post: post).with_deleted.count).to eq(1)
      PostActionDestroyer.destroy(codinghorror, post, :like)

      # Check that we don't lose consistency into negatives
      expect(post.reload.like_count).to eq(0)
    end
  end

  describe 'when a user likes something' do
    before do
      PostActionNotifier.enable
    end

    it 'should generate and remove notifications correctly' do
      PostActionCreator.like(codinghorror, post)

      expect(Notification.count).to eq(1)

      notification = Notification.last

      expect(notification.user_id).to eq(post.user_id)
      expect(notification.notification_type).to eq(Notification.types[:liked])

      PostActionDestroyer.destroy(codinghorror, post, :like)

      expect(Notification.count).to eq(0)

      PostActionCreator.like(codinghorror, post)

      expect(Notification.count).to eq(1)

      notification = Notification.last

      expect(notification.user_id).to eq(post.user_id)
      expect(notification.notification_type).to eq(Notification.types[:liked])
    end

    it 'should not notify when never is selected' do
      post.user.user_option.update!(
        like_notification_frequency:
          UserOption.like_notification_frequency_type[:never]
      )

      expect do
        PostActionCreator.like(codinghorror, post)
      end.to_not change { Notification.count }
    end

    it 'notifies on likes correctly' do
      SiteSetting.post_undo_action_window_mins = 120
      PostActionCreator.like(eviltrout, post)
      PostActionCreator.like(admin, post)

      # one like
      expect(Notification.where(post_number: 1, topic_id: post.topic_id).count)
        .to eq(1)

      post.user.user_option.update!(
        like_notification_frequency: UserOption.like_notification_frequency_type[:always]
      )

      admin2 = Fabricate(:admin)

      # Travel 1 hour in time to test that order post_actions by `created_at`
      freeze_time 1.hour.from_now

      expect do
        PostActionCreator.like(admin2, post)
      end.to_not change { Notification.count }

      # adds info to the notification
      notification = Notification.find_by(
        post_number: 1,
        topic_id: post.topic_id
      )

      expect(notification.data_hash["count"].to_i).to eq(2)
      expect(notification.data_hash["username2"]).to eq(eviltrout.username)

      # this is a tricky thing ... removing a like should fix up the notifications
      PostActionDestroyer.destroy(eviltrout, post, :like)

      # rebuilds the missing notification
      expect(Notification.where(post_number: 1, topic_id: post.topic_id).count)
        .to eq(1)

      notification = Notification.find_by(
        post_number: 1,
        topic_id: post.topic_id
      )

      expect(notification.data_hash["count"]).to eq(2)
      expect(notification.data_hash["username"]).to eq(admin2.username)
      expect(notification.data_hash["username2"]).to eq(admin.username)

      post.user.user_option.update!(
        like_notification_frequency:
        UserOption.like_notification_frequency_type[:first_time_and_daily]
      )

      # this gets skipped
      admin3 = Fabricate(:admin)
      PostActionCreator.like(admin3, post)

      freeze_time 2.days.from_now

      admin4 = Fabricate(:admin)
      PostActionCreator.like(admin4, post)

      # first happend within the same day, no need to notify
      expect(Notification.where(post_number: 1, topic_id: post.topic_id).count)
        .to eq(2)
    end

    describe 'likes consolidation' do
      fab!(:liker) { Fabricate(:user) }
      fab!(:liker2) { Fabricate(:user) }
      fab!(:likee) { Fabricate(:user) }

      it "can be disabled" do
        SiteSetting.notification_consolidation_threshold = 0

        expect do
          PostActionCreator.like(liker, Fabricate(:post, user: likee))
        end.to change { likee.reload.notifications.count }.by(1)

        SiteSetting.notification_consolidation_threshold = 1

        expect do
          PostActionCreator.like(liker, Fabricate(:post, user: likee))
        end.to_not change { likee.reload.notifications.count }
      end

      describe 'frequency first_time_and_daily' do
        before do
          likee.user_option.update!(
            like_notification_frequency:
              UserOption.like_notification_frequency_type[:first_time_and_daily]
          )
        end

        it 'should consolidate likes notification when the threshold is reached' do
          SiteSetting.notification_consolidation_threshold = 2

          expect do
            3.times do
              PostActionCreator.like(liker, Fabricate(:post, user: likee))
            end
          end.to change { likee.reload.notifications.count }.by(1)

          notification = likee.notifications.last

          expect(notification.notification_type).to eq(
            Notification.types[:liked_consolidated]
          )

          data = JSON.parse(notification.data)

          expect(data["username"]).to eq(liker.username)
          expect(data["display_username"]).to eq(liker.username)
          expect(data["count"]).to eq(3)

          notification.update!(read: true)

          expect do
            2.times do
              PostActionCreator.like(liker, Fabricate(:post, user: likee))
            end
          end.to_not change { likee.reload.notifications.count }

          data = JSON.parse(notification.reload.data)

          expect(notification.read).to eq(false)
          expect(data["count"]).to eq(5)

          # Like from a different user shouldn't be consolidated
          expect do
            PostActionCreator.like(Fabricate(:user), Fabricate(:post, user: likee))
          end.to change { likee.reload.notifications.count }.by(1)

          notification = likee.notifications.last

          expect(notification.notification_type).to eq(
            Notification.types[:liked]
          )

          freeze_time((
            SiteSetting.likes_notification_consolidation_window_mins.minutes +
            1
          ).since)

          expect do
            PostActionCreator.like(liker, Fabricate(:post, user: likee))
          end.to change { likee.reload.notifications.count }.by(1)

          notification = likee.notifications.last

          expect(notification.notification_type).to eq(Notification.types[:liked])
        end
      end

      describe 'frequency always' do
        before do
          likee.user_option.update!(
            like_notification_frequency:
              UserOption.like_notification_frequency_type[:always]
          )
        end

        it 'should consolidate liked notifications when threshold is reached' do
          SiteSetting.notification_consolidation_threshold = 2

          post = Fabricate(:post, user: likee)

          expect do
            [liker2, liker].each do |user|
              PostActionCreator.like(user, post)
            end
          end.to change { likee.reload.notifications.count }.by(1)

          notification = likee.notifications.last
          data_hash = notification.data_hash

          expect(data_hash["original_username"]).to eq(liker.username)
          expect(data_hash["username2"]).to eq(liker2.username)
          expect(data_hash["count"].to_i).to eq(2)

          expect do
            2.times do
              PostActionCreator.like(liker, Fabricate(:post, user: likee))
            end
          end.to change { likee.reload.notifications.count }.by(2)

          expect(likee.notifications.pluck(:notification_type).uniq)
            .to contain_exactly(Notification.types[:liked])

          expect do
            PostActionCreator.like(liker, Fabricate(:post, user: likee))
          end.to change { likee.reload.notifications.count }.by(-1)

          notification = likee.notifications.last

          expect(notification.notification_type).to eq(
            Notification.types[:liked_consolidated]
          )

          expect(notification.data_hash["count"].to_i).to eq(3)
          expect(notification.data_hash["username"]).to eq(liker.username)
        end
      end
    end

    it "should not generate a notification if liker has been muted" do
      mutee = Fabricate(:user)
      MutedUser.create!(user_id: post.user.id, muted_user_id: mutee.id)

      expect do
        PostActionCreator.like(mutee, post)
      end.to_not change { Notification.count }
    end

    it 'should not generate a notification if liker has the topic muted' do
      post = Fabricate(:post, user: eviltrout)

      TopicUser.create!(
        topic: post.topic,
        user: eviltrout,
        notification_level: TopicUser.notification_levels[:muted]
      )

      expect do
        PostActionCreator.like(codinghorror, post)
      end.to_not change { Notification.count }
    end

    it "should generate a notification if liker is an admin irregardles of \
      muting" do

      MutedUser.create!(user_id: post.user.id, muted_user_id: admin.id)

      expect do
        PostActionCreator.like(admin, post)
      end.to change { Notification.count }.by(1)

      notification = Notification.last

      expect(notification.user_id).to eq(post.user_id)
      expect(notification.notification_type).to eq(Notification.types[:liked])
    end

    it 'should increase the `like_count` and `like_score` when a user likes something' do
      freeze_time Date.today

      PostActionCreator.like(codinghorror, post)
      post.reload
      expect(post.like_count).to eq(1)
      expect(post.like_score).to eq(1)
      post.topic.reload
      expect(post.topic.like_count).to eq(1)
      expect(value_for(codinghorror.id, Date.today)).to eq(1)

      # When a staff member likes it
      PostActionCreator.like(moderator, post)
      post.reload
      expect(post.like_count).to eq(2)
      expect(post.like_score).to eq(4)
      expect(post.topic.like_count).to eq(2)

      # Removing likes
      PostActionDestroyer.destroy(codinghorror, post, :like)
      post.reload
      expect(post.like_count).to eq(1)
      expect(post.like_score).to eq(3)
      expect(post.topic.like_count).to eq(1)
      expect(value_for(codinghorror.id, Date.today)).to eq(0)

      PostActionDestroyer.destroy(moderator, post, :like)
      post.reload
      expect(post.like_count).to eq(0)
      expect(post.like_score).to eq(0)
      expect(post.topic.like_count).to eq(0)
    end

    it "shouldn't change given_likes unless likes are given or removed" do
      freeze_time(Time.zone.now)

      PostActionCreator.like(codinghorror, Fabricate(:post))
      expect(value_for(codinghorror.id, Date.today)).to eq(1)

      PostActionType.types.each do |type_name, type_id|
        post = Fabricate(:post)

        PostActionCreator.create(codinghorror, post, type_name)
        actual_count = value_for(codinghorror.id, Date.today)
        expected_count = type_name == :like ? 2 : 1
        expect(actual_count).to eq(expected_count), "Expected likes_given to be #{expected_count} when adding '#{type_name}', but got #{actual_count}"

        PostActionDestroyer.new(codinghorror, post, type_id).perform
        actual_count = value_for(codinghorror.id, Date.today)
        expect(actual_count).to eq(1), "Expected likes_given to be 1 when removing '#{type_name}', but got #{actual_count}"
      end
    end
  end

  describe 'flagging' do

    it 'does not allow you to flag stuff twice, even if the reason is different' do
      post = Fabricate(:post)
      expect(PostActionCreator.spam(eviltrout, post)).to be_success
      expect(PostActionCreator.off_topic(eviltrout, post)).to be_failed
    end

    it 'allows you to flag stuff again if your previous flag was removed' do
      post = Fabricate(:post)
      PostActionCreator.spam(eviltrout, post)
      PostActionDestroyer.destroy(eviltrout, post, :spam)
      expect(PostActionCreator.spam(eviltrout, post)).to be_success
    end

    it 'should update counts when you clear flags' do
      post = Fabricate(:post)
      reviewable = PostActionCreator.spam(eviltrout, post).reviewable

      expect(post.reload.spam_count).to eq(1)

      reviewable.perform(Discourse.system_user, :disagree)

      expect(post.reload.spam_count).to eq(0)
    end

    it "will not allow regular users to auto hide staff posts" do
      mod = Fabricate(:moderator)
      post = Fabricate(:post, user: mod)

      Reviewable.set_priorities(high: 2.0)
      SiteSetting.hide_post_sensitivity = Reviewable.sensitivity[:low]
      Discourse.stubs(:site_contact_user).returns(admin)

      PostActionCreator.spam(eviltrout, post)
      PostActionCreator.spam(Fabricate(:walter_white), post)

      expect(post.hidden).to eq(false)
      expect(post.hidden_at).to be_blank
    end

    it "allows staff users to auto hide staff posts" do
      mod = Fabricate(:moderator)
      post = Fabricate(:post, user: mod)

      Reviewable.set_priorities(high: 8.0)
      SiteSetting.hide_post_sensitivity = Reviewable.sensitivity[:low]
      Discourse.stubs(:site_contact_user).returns(admin)

      PostActionCreator.spam(eviltrout, post)
      PostActionCreator.spam(Fabricate(:admin), post)

      post.reload

      expect(post.hidden).to eq(true)
      expect(post.hidden_at).to be_present
    end

    it "will not trigger auto hide on like" do
      mod = Fabricate(:moderator)
      post = Fabricate(:post, user: mod)

      result = PostActionCreator.spam(eviltrout, post)
      result.reviewable.update!(score: 1000.0)
      PostActionCreator.like(Fabricate(:admin), post)

      post.reload

      expect(post.hidden).to eq(false)
    end

    it 'should follow the rules for automatic hiding workflow' do
      post = create_post
      walterwhite = Fabricate(:walter_white)

      Reviewable.set_priorities(high: 3.0)
      SiteSetting.hide_post_sensitivity = Reviewable.sensitivity[:low]
      Discourse.stubs(:site_contact_user).returns(admin)

      PostActionCreator.spam(eviltrout, post)
      PostActionCreator.spam(walterwhite, post)

      job_args = Jobs::SendSystemMessage.jobs.last["args"].first
      expect(job_args["user_id"]).to eq(post.user.id)
      expect(job_args["message_type"]).to eq("post_hidden")

      post.reload

      expect(post.hidden).to eq(true)
      expect(post.hidden_at).to be_present
      expect(post.hidden_reason_id).to eq(Post.hidden_reasons[:flag_threshold_reached])
      expect(post.topic.visible).to eq(false)

      post.revise(post.user, raw: post.raw + " ha I edited it ")

      post.reload

      expect(post.hidden).to eq(false)
      expect(post.hidden_reason_id).to eq(Post.hidden_reasons[:flag_threshold_reached]) # keep most recent reason
      expect(post.hidden_at).to be_present # keep the most recent hidden_at time
      expect(post.topic.visible).to eq(true)

      PostActionCreator.spam(eviltrout, post)
      PostActionCreator.off_topic(walterwhite, post)

      job_args = Jobs::SendSystemMessage.jobs.last["args"].first
      expect(job_args["user_id"]).to eq(post.user.id)
      expect(job_args["message_type"]).to eq("post_hidden_again")

      post.reload

      expect(post.hidden).to eq(true)
      expect(post.hidden_at).to be_present
      expect(post.hidden_reason_id).to eq(Post.hidden_reasons[:flag_threshold_reached_again])
      expect(post.topic.visible).to eq(false)

      post.revise(post.user, raw: post.raw + " ha I edited it again ")

      post.reload

      expect(post.hidden).to eq(true)
      expect(post.hidden_at).to be_present
      expect(post.hidden_reason_id).to eq(Post.hidden_reasons[:flag_threshold_reached_again])
      expect(post.topic.visible).to eq(false)
    end

    it "doesn't fail when post has nil user" do
      post = create_post
      post.update!(user: nil)

      PostActionCreator.new(moderator, post, PostActionType.types[:spam], take_action: true).perform
      post.reload
      expect(post.hidden).to eq(true)
    end
    it "hide tl0 posts that are flagged as spam by a tl3 user" do
      newuser = Fabricate(:newuser)
      post = create_post(user: newuser)

      Discourse.stubs(:site_contact_user).returns(admin)

      PostActionCreator.spam(Fabricate(:leader), post)

      post.reload

      expect(post.hidden).to eq(true)
      expect(post.hidden_at).to be_present
      expect(post.hidden_reason_id).to eq(Post.hidden_reasons[:flagged_by_tl3_user])
    end

    it "can flag the topic instead of a post" do
      post1 = create_post
      create_post(topic: post1.topic)
      result = PostActionCreator.new(
        Fabricate(:user),
        post1,
        PostActionType.types[:spam],
        flag_topic: true
      ).perform
      expect(result.post_action.targets_topic).to eq(true)
      expect(result.reviewable.payload['targets_topic']).to eq(true)
    end

    it "will flag the first post if you flag a topic but there is only one post in the topic" do
      post = create_post
      result = PostActionCreator.new(
        Fabricate(:user),
        post,
        PostActionType.types[:spam],
        flag_topic: true
      ).perform
      expect(result.post_action.targets_topic).to eq(false)
      expect(result.post_action.post_id).to eq(post.id)
      expect(result.reviewable.payload['targets_topic']).to eq(false)
    end

    it "will unhide the post when a moderator undos the flag on which s/he took action" do
      Discourse.stubs(:site_contact_user).returns(admin)

      post = create_post
      PostActionCreator.new(moderator, post, PostActionType.types[:spam], take_action: true).perform

      post.reload
      expect(post.hidden).to eq(true)

      PostActionDestroyer.destroy(moderator, post, :spam)

      post.reload
      expect(post.hidden).to eq(false)
    end

    context "topic auto closing" do
      fab!(:topic) { Fabricate(:topic) }
      let(:post1) { create_post(topic: topic) }
      let(:post2) { create_post(topic: topic) }
      let(:post3) { create_post(topic: topic) }

      fab!(:flagger1) { Fabricate(:user) }
      fab!(:flagger2) { Fabricate(:user) }

      before do
        SiteSetting.hide_post_sensitivity = Reviewable.sensitivity[:disabled]
        Reviewable.set_priorities(high: 4.5)
        SiteSetting.auto_close_topic_sensitivity = Reviewable.sensitivity[:low]
        SiteSetting.num_flaggers_to_close_topic = 2
        SiteSetting.num_hours_to_close_topic = 1
      end

      it "will automatically pause a topic due to large community flagging" do
        freeze_time

        # reaching `num_flaggers_to_close_topic` isn't enough
        [flagger1, flagger2].each do |flagger|
          PostActionCreator.inappropriate(flagger, post1)
        end

        expect(topic.reload.closed).to eq(false)

        # clean up
        PostAction.where(post: post1).delete_all

        # reaching `num_flags_to_close_topic` isn't enough
        [post1, post2, post3].each do |post|
          PostActionCreator.inappropriate(flagger1, post)
        end

        expect(topic.reload.closed).to eq(false)

        # clean up
        PostAction.where(post: [post1, post2, post3]).delete_all

        # reaching both should close the topic
        [flagger1, flagger2].each do |flagger|
          [post1, post2, post3].each do |post|
            PostActionCreator.inappropriate(flagger, post)
          end
        end

        expect(topic.reload.closed).to eq(true)

        topic_status_update = TopicTimer.last

        expect(topic_status_update.topic).to eq(topic)
        expect(topic_status_update.execute_at).to eq_time(1.hour.from_now)
        expect(topic_status_update.status_type).to eq(TopicTimer.types[:open])
      end

      context "on a staff post" do
        fab!(:staff_user) { Fabricate(:user, moderator: true) }
        fab!(:topic) { Fabricate(:topic, user: staff_user) }

        it "will not close topics opened by staff" do
          [flagger1, flagger2].each do |flagger|
            [post1, post2, post3].each do |post|
              PostActionCreator.inappropriate(flagger, post)
            end
          end

          expect(topic.reload.closed).to eq(false)
        end
      end

      it "will keep the topic in closed status until the community flags are handled" do
        freeze_time

        SiteSetting.num_flaggers_to_close_topic = 1
        Reviewable.set_priorities(high: 0.5)
        SiteSetting.auto_close_topic_sensitivity = Reviewable.sensitivity[:low]

        post = Fabricate(:post, topic: topic)
        PostActionCreator.spam(flagger1, post)
        expect(topic.reload.closed).to eq(true)

        timer = TopicTimer.last
        expect(timer.execute_at).to eq_time(1.hour.from_now)

        freeze_time timer.execute_at
        Jobs.expects(:enqueue_in).with(
          1.hour.to_i,
          :toggle_topic_closed,
          topic_timer_id: timer.id,
          state: false
        ).returns(true)
        Jobs::ToggleTopicClosed.new.execute(topic_timer_id: timer.id, state: false)

        expect(topic.reload.closed).to eq(true)
        expect(timer.reload.execute_at).to eq_time(1.hour.from_now)

        freeze_time timer.execute_at
        SiteSetting.num_flaggers_to_close_topic = 10
        Reviewable.set_priorities(high: 10.0)
        SiteSetting.auto_close_topic_sensitivity = Reviewable.sensitivity[:low]

        Jobs::ToggleTopicClosed.new.execute(topic_timer_id: timer.id, state: false)

        expect(topic.reload.closed).to eq(false)
      end

      it "will reopen topic after the flags are auto handled" do
        freeze_time
        [flagger1, flagger2].each do |flagger|
          [post1, post2, post3].each do |post|
            PostActionCreator.inappropriate(flagger, post)
          end
        end

        expect(topic.reload.closed).to eq(true)

        freeze_time 61.days.from_now
        Jobs::AutoQueueHandler.new.execute({})
        Jobs::ToggleTopicClosed.new.execute(topic_timer_id: TopicTimer.last.id, state: false)

        expect(topic.reload.closed).to eq(false)
      end
    end

  end

  it "prevents user to act twice at the same time" do
    # flags are already being tested
    all_types_except_flags = PostActionType.types.except(*PostActionType.flag_types_without_custom.keys)
    all_types_except_flags.values.each do |action|
      expect(PostActionCreator.new(eviltrout, post, action).perform).to be_success
      expect(PostActionCreator.new(eviltrout, post, action).perform).to be_failed
    end
  end

  describe "messages" do
    it "does not create a message when there is no message" do
      result = PostActionCreator.spam(Discourse.system_user, post)
      expect(result).to be_success
      expect(result.post_action.related_post_id).to be_nil
      expect(result.reviewable_score.meta_topic_id).to be_nil
    end

    [:notify_moderators, :notify_user, :spam].each do |post_action_type|
      it "creates a message for #{post_action_type}" do
        result = PostActionCreator.new(
          Discourse.system_user,
          post,
          PostActionType.types[post_action_type],
          message: 'WAT'
        ).perform
        expect(result).to be_success
        expect(result.post_action.related_post_id).to be_present
      end
    end

    it "should raise the right errors when it fails to create a post" do
      begin
        group = Group[:moderators]
        messageable_level = group.messageable_level
        group.update!(messageable_level: Group::ALIAS_LEVELS[:nobody])

        result = PostActionCreator.notify_moderators(Fabricate(:user), post, 'testing')
        expect(result).to be_failed
      ensure
        group.update!(messageable_level: messageable_level)
      end
    end

    it "should succeed even with low max title length" do
      SiteSetting.max_topic_title_length = 50
      post.topic.title = 'This is a test topic ' * 2
      post.topic.save!

      result = PostActionCreator.notify_moderators(Discourse.system_user, post, 'WAT')
      expect(result).to be_success
      expect(result.post_action.related_post_id).to be_present
    end
  end

  describe ".lookup_for" do
    it "returns the correct map" do
      user = Fabricate(:user)
      post = Fabricate(:post)
      post_action = PostActionCreator.create(user, post, :bookmark).post_action
      map = PostAction.lookup_for(user, [post.topic], post_action.post_action_type_id)

      expect(map).to eq(post.topic_id => [post.post_number])
    end
  end

  describe "#add_moderator_post_if_needed" do

    it "should not add a moderator post when it's disabled" do
      post = create_post

      result = PostActionCreator.create(moderator, post, :spam, message: "WAT")
      topic = result.post_action.related_post.topic
      expect(topic.posts.count).to eq(1)

      SiteSetting.auto_respond_to_flag_actions = false
      result.reviewable.perform(admin, :agree_and_keep)
      expect(topic.reload.posts.count).to eq(1)
    end

    it "should create a notification in the related topic" do
      Jobs.run_immediately!
      post = Fabricate(:post)
      user = Fabricate(:user)
      result = PostActionCreator.create(user, post, :spam, message: "WAT")
      topic = result.post_action.related_post.topic
      reviewable = result.reviewable
      expect(user.notifications.count).to eq(0)

      SiteSetting.auto_respond_to_flag_actions = true
      reviewable.perform(admin, :agree_and_keep)

      user_notifications = user.notifications
      expect(user_notifications.last.topic).to eq(topic)
    end

    skip "should not add a moderator post when post is flagged via private message" do
      Jobs.run_immediately!
      post = Fabricate(:post)
      user = Fabricate(:user)
      result = PostActionCreator.create(user, post, :notify_user, message: "WAT")
      action = result.post_action
      action.reload.related_post.topic
      expect(user.notifications.count).to eq(0)

      SiteSetting.auto_respond_to_flag_actions = true
      result.reviewable.perform(admin, :agree_and_keep)
      expect(user.reload.user_stat.flags_agreed).to eq(0)

      user_notifications = user.notifications
      expect(user_notifications.count).to eq(0)
    end
  end

  describe "rate limiting" do

    def limiter(tl)
      user = Fabricate.build(:user)
      user.trust_level = tl
      action = PostAction.new(user: user, post_action_type_id: PostActionType.types[:like])
      action.post_action_rate_limiter
    end

    it "should scale up like limits depending on liker" do
      expect(limiter(0).max).to eq SiteSetting.max_likes_per_day
      expect(limiter(1).max).to eq SiteSetting.max_likes_per_day
      expect(limiter(2).max).to eq (SiteSetting.max_likes_per_day * SiteSetting.tl2_additional_likes_per_day_multiplier).to_i
      expect(limiter(3).max).to eq (SiteSetting.max_likes_per_day * SiteSetting.tl3_additional_likes_per_day_multiplier).to_i
      expect(limiter(4).max).to eq (SiteSetting.max_likes_per_day * SiteSetting.tl4_additional_likes_per_day_multiplier).to_i

      SiteSetting.tl2_additional_likes_per_day_multiplier = -1
      expect(limiter(2).max).to eq SiteSetting.max_likes_per_day

      SiteSetting.tl2_additional_likes_per_day_multiplier = 0.8
      expect(limiter(2).max).to eq SiteSetting.max_likes_per_day

      SiteSetting.tl2_additional_likes_per_day_multiplier = "bob"
      expect(limiter(2).max).to eq SiteSetting.max_likes_per_day
    end

  end

  describe '#is_flag?' do
    describe 'when post action is a flag' do
      it 'should return true' do
        PostActionType.notify_flag_types.each do |_type, id|
          post_action = PostAction.new(
            user: codinghorror,
            post_action_type_id: id
          )

          expect(post_action.is_flag?).to eq(true)
        end
      end
    end

    describe 'when post action is not a flag' do
      it 'should return false' do
        post_action = PostAction.new(
          user: codinghorror,
          post_action_type_id: 99
        )

        expect(post_action.is_flag?).to eq(false)
      end
    end
  end

  describe "triggers Discourse events" do
    fab!(:post) { Fabricate(:post) }

    it 'triggers a flag_created event' do
      event = DiscourseEvent.track(:flag_created) { PostActionCreator.spam(eviltrout, post) }
      expect(event).to be_present
    end

    context "resolving flags" do
      let(:result) { PostActionCreator.spam(eviltrout, post) }
      let(:post_action) { result.post_action }
      let(:reviewable) { result.reviewable }

      it 'creates events for agreed' do
        events = DiscourseEvent.track_events { reviewable.perform(moderator, :agree_and_keep) }

        reviewed_event = events.find { |e| e[:event_name] == :flag_reviewed }
        expect(reviewed_event).to be_present

        event = events.find { |e| e[:event_name] == :flag_agreed }
        expect(event).to be_present
        expect(event[:params]).to eq([post_action])
      end

      it 'creates events for disagreed' do
        events = DiscourseEvent.track_events { reviewable.perform(moderator, :disagree) }

        reviewed_event = events.find { |e| e[:event_name] == :flag_reviewed }
        expect(reviewed_event).to be_present

        event = events.find { |e| e[:event_name] == :flag_disagreed }
        expect(event).to be_present
        expect(event[:params]).to eq([post_action])
      end

      it 'creates events for ignored' do
        events = DiscourseEvent.track_events { reviewable.perform(moderator, :ignore) }

        reviewed_event = events.find { |e| e[:event_name] == :flag_reviewed }
        expect(reviewed_event).to be_present

        event = events.find { |e| e[:event_name] == :flag_deferred }
        expect(event).to be_present
        expect(event[:params]).to eq([post_action])
      end
    end
  end
end

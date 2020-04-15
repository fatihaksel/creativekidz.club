# frozen_string_literal: true

require 'rails_helper'

describe BadgeGranter do

  fab!(:badge) { Fabricate(:badge) }
  fab!(:user) { Fabricate(:user) }

  describe 'revoke_titles' do
    it 'can correctly revoke titles' do
      badge = Fabricate(:badge, allow_title: true)
      user = Fabricate(:user, title: badge.name)
      user.reload

      user.user_profile.update_column(:badge_granted_title, true)

      BadgeGranter.grant(badge, user)
      BadgeGranter.revoke_ungranted_titles!

      user.reload
      expect(user.title).to eq(badge.name)

      badge.update_column(:allow_title, false)
      BadgeGranter.revoke_ungranted_titles!

      user.reload
      expect(user.title).to eq('')

      user.title = "CEO"
      user.save

      BadgeGranter.revoke_ungranted_titles!

      user.reload
      expect(user.title).to eq("CEO")
    end
  end

  describe 'preview' do
    it 'can correctly preview' do
      Fabricate(:user, email: 'sam@gmail.com')
      result = BadgeGranter.preview('select u.id user_id, null post_id, u.created_at granted_at from users u
                                     join user_emails ue on ue.user_id = u.id AND ue.primary
                                     where ue.email like \'%gmail.com\'', explain: true)

      expect(result[:grant_count]).to eq(1)
      expect(result[:query_plan]).to be_present
    end

    it 'with badges containing trailing comments do not break generated SQL' do
      query = Badge.find(1).query + "\n-- a comment"
      expect(BadgeGranter.preview(query)[:errors]).to be_nil
    end
  end

  describe 'backfill' do

    it 'has no broken badge queries' do
      Badge.all.each do |b|
        BadgeGranter.backfill(b)
      end
    end

    it 'can backfill the welcome badge' do
      post = Fabricate(:post)
      user2 = Fabricate(:user)
      PostActionCreator.like(user2, post)

      UserBadge.destroy_all
      BadgeGranter.backfill(Badge.find(Badge::Welcome))
      BadgeGranter.backfill(Badge.find(Badge::FirstLike))

      b = UserBadge.find_by(user_id: post.user_id)
      expect(b.post_id).to eq(post.id)
      b.badge_id = Badge::Welcome

      b = UserBadge.find_by(user_id: user2.id)
      expect(b.post_id).to eq(post.id)
      b.badge_id = Badge::FirstLike
    end

    it 'should grant missing badges' do
      nice_topic = Badge.find(Badge::NiceTopic)
      good_topic = Badge.find(Badge::GoodTopic)

      post = Fabricate(:post, like_count: 30)

      2.times {
        BadgeGranter.backfill(nice_topic, post_ids: [post.id])
        BadgeGranter.backfill(good_topic)
      }

      # TODO add welcome
      expect(post.user.user_badges.pluck(:badge_id)).to contain_exactly(nice_topic.id, good_topic.id)
      expect(post.user.notifications.count).to eq(2)

      data = post.user.notifications.last.data_hash
      expect(data["badge_id"]).to eq(good_topic.id)
      expect(data["badge_slug"]).to eq(good_topic.slug)
      expect(data["username"]).to eq(post.user.username)

      expect(nice_topic.grant_count).to eq(1)
      expect(good_topic.grant_count).to eq(1)
    end

    it 'should grant badges in the user locale' do
      SiteSetting.allow_user_locale = true

      nice_topic = Badge.find(Badge::NiceTopic)
      name_english = nice_topic.name

      user = Fabricate(:user, locale: 'fr')
      post = Fabricate(:post, like_count: 10, user: user)

      BadgeGranter.backfill(nice_topic)

      notification_badge_name = JSON.parse(post.user.notifications.first.data)['badge_name']

      expect(notification_badge_name).not_to eq(name_english)
    end

    it 'with badges containing trailing comments do not break generated SQL' do
      badge = Fabricate(:badge)
      badge.query = Badge.find(1).query + "\n-- a comment"
      expect { BadgeGranter.backfill(badge) }.not_to raise_error
    end
  end

  describe 'grant' do

    it 'allows overriding of granted_at does not notify old bronze' do
      freeze_time
      badge = Badge.create!(name: 'a badge', badge_type_id: BadgeType::Bronze)
      user_badge = BadgeGranter.grant(badge, user, created_at: 1.year.ago)

      expect(user_badge.granted_at).to eq_time(1.year.ago)
      expect(Notification.where(user_id: user.id).count).to eq(0)
    end

    it "doesn't grant disabled badges" do
      freeze_time
      badge = Fabricate(:badge, badge_type_id: BadgeType::Bronze, enabled: false)

      user_badge = BadgeGranter.grant(badge, user, created_at: 1.year.ago)
      expect(user_badge).to eq(nil)
    end

    it 'grants multiple badges' do
      badge = Fabricate(:badge, multiple_grant: true)
      user_badge = BadgeGranter.grant(badge, user)
      user_badge = BadgeGranter.grant(badge, user)
      expect(user_badge).to be_present

      expect(UserBadge.where(user_id: user.id).count).to eq(2)
    end

    it 'sets granted_at' do
      day_ago = freeze_time 1.day.ago
      user_badge = BadgeGranter.grant(badge, user)

      expect(user_badge.granted_at).to eq_time(day_ago)
    end

    it 'sets granted_by if the option is present' do
      admin = Fabricate(:admin)
      StaffActionLogger.any_instance.expects(:log_badge_grant).once
      user_badge = BadgeGranter.grant(badge, user, granted_by: admin)
      expect(user_badge.granted_by).to eq(admin)
    end

    it 'defaults granted_by to the system user' do
      StaffActionLogger.any_instance.expects(:log_badge_grant).never
      user_badge = BadgeGranter.grant(badge, user)
      expect(user_badge.granted_by_id).to eq(Discourse.system_user.id)
    end

    it 'does not allow a regular user to grant badges' do
      user_badge = BadgeGranter.grant(badge, user, granted_by: Fabricate(:user))
      expect(user_badge).not_to be_present
    end

    it 'increments grant_count on the badge and creates a notification' do
      BadgeGranter.grant(badge, user)
      expect(badge.reload.grant_count).to eq(1)
      expect(user.notifications.find_by(notification_type: Notification.types[:granted_badge]).data_hash["badge_id"]).to eq(badge.id)
    end

  end

  describe 'revoke' do

    fab!(:admin) { Fabricate(:admin) }
    let!(:user_badge) { BadgeGranter.grant(badge, user) }

    it 'revokes the badge and does necessary cleanup' do
      user.title = badge.name; user.save!
      expect(badge.reload.grant_count).to eq(1)
      StaffActionLogger.any_instance.expects(:log_badge_revoke).with(user_badge)
      BadgeGranter.revoke(user_badge, revoked_by: admin)
      expect(UserBadge.find_by(user: user, badge: badge)).not_to be_present
      expect(badge.reload.grant_count).to eq(0)
      expect(user.notifications.where(notification_type: Notification.types[:granted_badge])).to be_empty
      expect(user.reload.title).to eq(nil)
    end

    context 'when the badge name is customized, and the customized name is the same as the user title' do
      let(:customized_badge_name) { 'Merit Badge' }

      before do
        TranslationOverride.upsert!(I18n.locale, Badge.i18n_key(badge.name), customized_badge_name)
      end

      it 'revokes the badge and title and does necessary cleanup' do
        user.title = customized_badge_name; user.save!
        expect(badge.reload.grant_count).to eq(1)
        StaffActionLogger.any_instance.expects(:log_badge_revoke).with(user_badge)
        StaffActionLogger.any_instance.expects(:log_title_revoke).with(
          user,
          revoke_reason: 'user title was same as revoked badge name or custom badge name',
          previous_value: user_badge.user.title
        )
        BadgeGranter.revoke(user_badge, revoked_by: admin)
        expect(UserBadge.find_by(user: user, badge: badge)).not_to be_present
        expect(badge.reload.grant_count).to eq(0)
        expect(user.notifications.where(notification_type: Notification.types[:granted_badge])).to be_empty
        expect(user.reload.title).to eq(nil)
      end

      after do
        TranslationOverride.revert!(I18n.locale, Badge.i18n_key(badge.name))
      end
    end
  end

  describe 'revoke_all' do
    it 'deletes every user_badge record associated with that badge' do
      described_class.grant(badge, user)
      described_class.revoke_all(badge)

      expect(UserBadge.exists?(badge: badge, user: user)).to eq(false)
    end

    it 'removes titles' do
      another_title = 'another title'
      described_class.grant(badge, user)
      user.update!(title: badge.name)
      user2 = Fabricate(:user, title: another_title)

      described_class.revoke_all(badge)

      expect(user.reload.title).to be_nil
      expect(user2.reload.title).to eq(another_title)
    end

    it 'removes custom badge titles' do
      custom_badge_title = 'this is a badge title'
      TranslationOverride.create!(translation_key: badge.translation_key, value: custom_badge_title, locale: 'en_US')
      described_class.grant(badge, user)
      user.update!(title: custom_badge_title)

      described_class.revoke_all(badge)

      expect(user.reload.title).to be_nil
    end
  end

  context "update_badges" do
    fab!(:user) { Fabricate(:user) }
    fab!(:liker) { Fabricate(:user) }

    before do
      BadgeGranter.clear_queue!
    end

    it "grants autobiographer" do
      user.user_profile.bio_raw = "THIS IS MY bio it a long bio I like my bio"
      user.uploaded_avatar_id = 10
      user.user_profile.save
      user.save

      BadgeGranter.process_queue!
      expect(UserBadge.where(user_id: user.id, badge_id: Badge::Autobiographer).count).to eq(1)
    end

    it "grants read guidlines" do
      user.user_stat.read_faq = Time.now
      user.user_stat.save

      BadgeGranter.process_queue!
      expect(UserBadge.where(user_id: user.id, badge_id: Badge::ReadGuidelines).count).to eq(1)
    end

    it "grants first link" do
      post = create_post
      post2 = create_post(raw: "#{Discourse.base_url}/t/slug/#{post.topic_id}")

      BadgeGranter.process_queue!
      expect(UserBadge.where(user_id: post2.user.id, badge_id: Badge::FirstLink).count).to eq(1)
    end

    it "grants first edit" do
      SiteSetting.editing_grace_period = 0
      post = create_post
      user = post.user

      expect(UserBadge.where(user_id: user.id, badge_id: Badge::Editor).count).to eq(0)

      PostRevisor.new(post).revise!(user, raw: "This is my new test 1235 123")
      BadgeGranter.process_queue!

      expect(UserBadge.where(user_id: user.id, badge_id: Badge::Editor).count).to eq(1)
    end

    it "grants and revokes trust level badges" do
      user.change_trust_level!(TrustLevel[4])
      BadgeGranter.process_queue!
      expect(UserBadge.where(user_id: user.id, badge_id: Badge.trust_level_badge_ids).count).to eq(4)

      user.change_trust_level!(TrustLevel[1])
      BadgeGranter.backfill(Badge.find(1))
      BadgeGranter.backfill(Badge.find(2))
      expect(UserBadge.where(user_id: user.id, badge_id: 1).first).not_to eq(nil)
      expect(UserBadge.where(user_id: user.id, badge_id: 2).first).to eq(nil)
    end

    it "grants system like badges" do
      post = create_post(user: user)
      # Welcome badge
      action = PostActionCreator.like(liker, post).post_action
      BadgeGranter.process_queue!
      expect(UserBadge.find_by(user_id: user.id, badge_id: 5)).not_to eq(nil)

      post = create_post(topic: post.topic, user: user)
      action = PostActionCreator.like(liker, post).post_action

      # Nice post badge
      post.update like_count: 10

      BadgeGranter.queue_badge_grant(Badge::Trigger::PostAction, post_action: action)
      BadgeGranter.process_queue!

      expect(UserBadge.find_by(user_id: user.id, badge_id: Badge::NicePost)).not_to eq(nil)
      expect(UserBadge.where(user_id: user.id, badge_id: Badge::NicePost).count).to eq(1)

      # Good post badge
      post.update like_count: 25
      BadgeGranter.queue_badge_grant(Badge::Trigger::PostAction, post_action: action)
      BadgeGranter.process_queue!
      expect(UserBadge.find_by(user_id: user.id, badge_id: Badge::GoodPost)).not_to eq(nil)

      # Great post badge
      post.update like_count: 50
      BadgeGranter.queue_badge_grant(Badge::Trigger::PostAction, post_action: action)
      BadgeGranter.process_queue!
      expect(UserBadge.find_by(user_id: user.id, badge_id: Badge::GreatPost)).not_to eq(nil)

      # Revoke badges on unlike
      post.update like_count: 49
      BadgeGranter.backfill(Badge.find(Badge::GreatPost))
      expect(UserBadge.find_by(user_id: user.id, badge_id: Badge::GreatPost)).to eq(nil)
    end
  end

  context 'notification locales' do
    it 'is using default locales when user locales are not set' do
      SiteSetting.allow_user_locale = true
      expect(BadgeGranter.notification_locale('')).to eq(SiteSetting.default_locale)
    end

    it 'is using default locales when user locales are set but is not allowed' do
      SiteSetting.allow_user_locale = false
      expect(BadgeGranter.notification_locale('pl_PL')).to eq(SiteSetting.default_locale)
    end

    it 'is using user locales when set and allowed' do
      SiteSetting.allow_user_locale = true
      expect(BadgeGranter.notification_locale('pl_PL')).to eq('pl_PL')
    end
  end
end

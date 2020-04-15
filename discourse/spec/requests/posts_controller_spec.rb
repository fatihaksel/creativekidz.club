# frozen_string_literal: true

require 'rails_helper'

shared_examples 'finding and showing post' do
  let!(:post) { post_by_user }

  it "ensures the user can't see the post" do
    topic = post.topic
    topic.convert_to_private_message(Discourse.system_user)
    topic.remove_allowed_user(Discourse.system_user, user.username)
    get url
    expect(response).to be_forbidden
  end

  it 'succeeds' do
    get url
    expect(response.status).to eq(200)
  end

  context "deleted post" do
    before do
      post.trash!(user)
    end

    it "can't find deleted posts as an anonymous user" do
      get url
      expect(response.status).to eq(404)
    end

    it "can't find deleted posts as a regular user" do
      sign_in(user)
      get url
      expect(response.status).to eq(404)
    end

    it "can find posts as a moderator" do
      sign_in(moderator)
      get url
      expect(response.status).to eq(200)
    end

    it "can find posts as a admin" do
      sign_in(admin)
      get url
      expect(response.status).to eq(200)
    end
  end
end

shared_examples 'action requires login' do |method, url, params = {}|
  it 'raises an exception when not logged in' do
    self.public_send(method, url, params)
    expect(response.status).to eq(403)
  end
end

describe PostsController do
  fab!(:admin) { Fabricate(:admin) }
  fab!(:moderator) { Fabricate(:moderator) }
  fab!(:user) { Fabricate(:user) }
  fab!(:category) { Fabricate(:category) }
  fab!(:topic) { Fabricate(:topic) }
  fab!(:post_by_user) { Fabricate(:post, user: user) }
  let(:public_post) { Fabricate(:post, user: user, topic: topic) }
  let(:topicless_post) { Fabricate(:post, user: user, raw: '<p>Car 54, where are you?</p>') }

  let(:private_topic) do
    Fabricate(:topic, archetype: Archetype.private_message, category_id: nil)
  end

  let(:private_post) { Fabricate(:post, user: user, topic: private_topic) }

  describe '#show' do
    include_examples 'finding and showing post' do
      let(:url) { "/posts/#{post.id}.json" }
    end

    it 'gets all the expected fields' do
      # non fabricated test
      new_post = create_post

      get "/posts/#{new_post.id}.json"
      parsed = JSON.parse(response.body)

      expect(parsed["topic_slug"]).to eq(new_post.topic.slug)
      expect(parsed["moderator"]).to eq(false)
      expect(parsed["username"]).to eq(new_post.user.username)
      expect(parsed["cooked"]).to eq(new_post.cooked)
    end
  end

  describe '#by_number' do
    include_examples 'finding and showing post' do
      let(:url) { "/posts/by_number/#{post.topic_id}/#{post.post_number}.json" }
    end
  end

  describe '#by_date' do
    include_examples 'finding and showing post' do
      let(:url) { "/posts/by-date/#{post.topic_id}/#{post.created_at.strftime("%Y-%m-%d")}.json" }
    end

    it 'returns the expected post' do
      first_post = Fabricate(:post, created_at: 10.days.ago)
      second_post = Fabricate(:post, topic: first_post.topic, created_at: 4.days.ago)
      _third_post = Fabricate(:post, topic: first_post.topic, created_at: 3.days.ago)

      get "/posts/by-date/#{second_post.topic_id}/#{(second_post.created_at - 2.days).strftime("%Y-%m-%d")}.json"
      json = JSON.parse(response.body)

      expect(response.status).to eq(200)
      expect(json["id"]).to eq(second_post.id)
    end

    it 'returns no post if date is > at last created post' do
      get "/posts/by-date/#{post.topic_id}/2245-11-11.json"
      _json = JSON.parse(response.body)
      expect(response.status).to eq(404)
    end
  end

  describe '#reply_history' do
    include_examples 'finding and showing post' do
      let(:url) { "/posts/#{post.id}/reply-history.json" }
    end

    it "returns the replies with whitelisted user custom fields" do
      parent = Fabricate(:post)
      child = Fabricate(:post, topic: parent.topic, reply_to_post_number: parent.post_number)

      parent.user.upsert_custom_fields(hello: 'world', hidden: 'dontshow')
      SiteSetting.public_user_custom_fields = 'hello'

      get "/posts/#{child.id}/reply-history.json"
      expect(response.status).to eq(200)

      json = JSON.parse(response.body)
      expect(json[0]['id']).to eq(parent.id)
      expect(json[0]['user_custom_fields']['hello']).to eq('world')
      expect(json[0]['user_custom_fields']['hidden']).to be_blank
    end
  end

  describe '#replies' do
    include_examples 'finding and showing post' do
      let(:url) { "/posts/#{post.id}/replies.json" }
    end

    it 'asks post for replies' do
      parent = Fabricate(:post)
      child = Fabricate(:post, topic: parent.topic, reply_to_post_number: parent.post_number)
      PostReply.create!(post: parent, reply: child)

      child.user.upsert_custom_fields(hello: 'world', hidden: 'dontshow')
      SiteSetting.public_user_custom_fields = 'hello'

      get "/posts/#{parent.id}/replies.json"
      expect(response.status).to eq(200)

      json = JSON.parse(response.body)
      expect(json[0]['id']).to eq(child.id)
      expect(json[0]['user_custom_fields']['hello']).to eq('world')
      expect(json[0]['user_custom_fields']['hidden']).to be_blank
    end
  end

  describe '#destroy' do
    include_examples 'action requires login', :delete, "/posts/123.json"

    describe 'when logged in' do
      let(:topic) { Fabricate(:topic) }

      it "raises an error when the user doesn't have permission to see the post" do
        pm = Fabricate(:private_message_topic)
        post = Fabricate(:post, topic: pm, post_number: 3)

        sign_in(user)

        delete "/posts/#{post.id}.json"
        expect(response).to be_forbidden
      end

      it "uses a PostDestroyer" do
        post = Fabricate(:post, topic_id: topic.id, post_number: 3)
        sign_in(moderator)

        destroyer = mock
        PostDestroyer.expects(:new).returns(destroyer)
        destroyer.expects(:destroy)

        delete "/posts/#{post.id}.json"
      end
    end
  end

  describe '#destroy_many' do
    include_examples 'action requires login', :delete, "/posts/destroy_many.json", params: { post_ids: [123, 345] }

    describe 'when logged in' do
      fab!(:poster) { Fabricate(:moderator) }
      fab!(:post1) { Fabricate(:post, user: poster, post_number: 2) }
      fab!(:post2) { Fabricate(:post, topic: post1.topic, user: poster, post_number: 3, reply_to_post_number: post1.post_number) }

      it "raises invalid parameters no post_ids" do
        sign_in(poster)
        delete "/posts/destroy_many.json"
        expect(response.status).to eq(400)
        expect(response.message.downcase).to eq("bad request")
      end

      it "raises invalid parameters with missing ids" do
        sign_in(poster)
        delete "/posts/destroy_many.json", params: { post_ids: [12345] }
        expect(response.status).to eq(400)
      end

      it "raises an error when the user doesn't have permission to delete the posts" do
        sign_in(user)
        delete "/posts/destroy_many.json", params: { post_ids: [post1.id, post2.id] }
        expect(response).to be_forbidden
      end

      it "deletes the post" do
        sign_in(poster)
        PostDestroyer.any_instance.expects(:destroy).twice
        delete "/posts/destroy_many.json", params: { post_ids: [post1.id, post2.id] }
        expect(response.status).to eq(200)
      end

      it "updates the highest read data for the forum" do
        sign_in(poster)
        Topic.expects(:reset_highest).twice
        delete "/posts/destroy_many.json", params: { post_ids: [post1.id, post2.id] }
      end

      describe "can delete replies" do
        before do
          PostReply.create(post_id: post1.id, reply_post_id: post2.id)
        end

        it "deletes the post and the reply to it" do
          sign_in(poster)
          PostDestroyer.any_instance.expects(:destroy).twice
          delete "/posts/destroy_many.json", params: { post_ids: [post1.id], reply_post_ids: [post1.id] }
        end
      end

      context "deleting flagged posts" do
        before do
          sign_in(moderator)
          PostActionCreator.off_topic(moderator, post1)
          PostActionCreator.off_topic(moderator, post2)
          Jobs::SendSystemMessage.clear
        end

        it "defers the child posts by default" do
          expect(ReviewableFlaggedPost.pending.count).to eq(2)
          delete "/posts/destroy_many.json", params: { post_ids: [post1.id, post2.id] }
          expect(Jobs::SendSystemMessage.jobs.size).to eq(1)
          expect(ReviewableFlaggedPost.pending.count).to eq(0)
        end

        it "can defer all posts based on `agree_with_first_reply_flag` param" do
          expect(ReviewableFlaggedPost.pending.count).to eq(2)
          delete "/posts/destroy_many.json", params: { post_ids: [post1.id, post2.id], agree_with_first_reply_flag: false }
          PostActionCreator.off_topic(moderator, post1)
          PostActionCreator.off_topic(moderator, post2)
          Jobs::SendSystemMessage.clear
        end
      end
    end
  end

  describe '#recover' do
    include_examples 'action requires login', :put, "/posts/123/recover.json"

    describe 'when logged in' do
      it "raises an error when the user doesn't have permission to see the post" do
        post = Fabricate(:post, topic: Fabricate(:private_message_topic), post_number: 3)
        sign_in(user)

        put "/posts/#{post.id}/recover.json"
        expect(response).to be_forbidden
      end

      it "recovers a post correctly" do
        topic_id = create_post.topic_id
        post = create_post(topic_id: topic_id)
        sign_in(user)

        PostDestroyer.new(user, post).destroy
        put "/posts/#{post.id}/recover.json"
        post.reload
        expect(post.trashed?).to be_falsey
      end
    end
  end

  describe '#update' do
    include_examples 'action requires login', :put, "/posts/2.json"

    let!(:post) { post_by_user }
    let(:update_params) do
      {
        post: { raw: 'edited body', edit_reason: 'typo' },
        image_sizes: { 'http://image.com/image.jpg' => { 'width' => 123, 'height' => 456 } },
      }
    end

    describe 'when logged in as a regular user' do
      before do
        sign_in(user)
      end

      it 'does not allow TL0 or TL1 to update when edit time limit expired' do
        SiteSetting.post_edit_time_limit = 5
        SiteSetting.tl2_post_edit_time_limit = 30

        post = Fabricate(:post, created_at: 10.minutes.ago, user: user)

        user.update_columns(trust_level: 1)

        put "/posts/#{post.id}.json", params: update_params

        expect(response.status).to eq(422)
        expect(JSON.parse(response.body)['errors']).to include(I18n.t('too_late_to_edit'))
      end

      it 'does not allow TL2 to update when edit time limit expired' do
        SiteSetting.post_edit_time_limit = 12
        SiteSetting.tl2_post_edit_time_limit = 8

        user.update_columns(trust_level: 2)

        post = Fabricate(:post, created_at: 10.minutes.ago, user: user)

        put "/posts/#{post.id}.json", params: update_params

        expect(response.status).to eq(422)
        expect(JSON.parse(response.body)['errors']).to include(I18n.t('too_late_to_edit'))
      end

      it 'passes the image sizes through' do
        Post.any_instance.expects(:image_sizes=)
        put "/posts/#{post.id}.json", params: update_params
      end

      it 'passes the edit reason through' do
        put "/posts/#{post.id}.json", params: update_params
        expect(response.status).to eq(200)
        post.reload
        expect(post.edit_reason).to eq("typo")
        expect(post.raw).to eq("edited body")
      end

      it 'checks for an edit conflict' do
        update_params[:post][:raw_old] = 'old body'
        put "/posts/#{post.id}.json", params: update_params

        expect(response.status).to eq(409)
      end

      it "raises an error when the post parameter is missing" do
        update_params.delete(:post)
        put "/posts/#{post.id}.json", params: update_params
        expect(response.status).to eq(400)
        expect(response.message.downcase).to eq("bad request")
      end

      it "raises an error when the user doesn't have permission to see the post" do
        post = Fabricate(:private_message_post, post_number: 3)
        put "/posts/#{post.id}.json", params: update_params
        expect(response).to be_forbidden
      end

      it "calls revise with valid parameters" do
        PostRevisor.any_instance.expects(:revise!).with(post.user, { raw: 'edited body' , edit_reason: 'typo' }, anything)
        put "/posts/#{post.id}.json", params: update_params
      end

      it "extracts links from the new body" do
        param = update_params
        param[:post][:raw] = 'I just visited this https://google.com so many cool links'

        put "/posts/#{post.id}.json", params: param

        expect(response.status).to eq(200)
        expect(TopicLink.count).to eq(1)
      end

      it "doesn't allow updating of deleted posts" do
        first_post = post.topic.ordered_posts.first
        PostDestroyer.new(moderator, first_post).destroy

        put "/posts/#{first_post.id}.json", params: update_params
        expect(response).not_to be_successful
      end
    end

    describe "when logged in as staff" do
      before do
        sign_in(moderator)
      end

      it "supports updating posts in deleted topics" do
        first_post = post.topic.ordered_posts.first
        PostDestroyer.new(moderator, first_post).destroy

        put "/posts/#{first_post.id}.json", params: update_params
        expect(response.status).to eq(200)

        post.reload
        expect(post.raw).to eq('edited body')
      end

      it "won't update bump date if post is a whisper" do
        created_at = freeze_time 1.day.ago
        post = Fabricate(:post, post_type: Post.types[:whisper], user: user)

        unfreeze_time
        put "/posts/#{post.id}.json", params: update_params

        expect(response.status).to eq(200)
        expect(post.topic.reload.bumped_at).to eq_time(created_at)
      end
    end

    it 'can not change category to a disallowed category' do
      post = create_post
      sign_in(post.user)

      category = Fabricate(:category)
      category.set_permissions(staff: :full)
      category.save!

      put "/posts/#{post.id}.json", params: {
        post: { category_id: category.id, raw: "this is a test edit to post" }
      }

      expect(response.status).not_to eq(200)
      expect(post.topic.category_id).not_to eq(category.id)
    end

    it 'can not move to a category that requires topic approval' do
      post = create_post
      sign_in(post.user)

      category = Fabricate(:category)
      category.custom_fields[Category::REQUIRE_TOPIC_APPROVAL] = true
      category.save!

      put "/posts/#{post.id}.json", params: { post: { category_id: category.id, raw: "this is a test edit to post" } }

      expect(response.status).to eq(403)
      expect(post.topic.reload.category_id).not_to eq(category.id)
    end
  end

  describe "#destroy_bookmark" do
    fab!(:post) { Fabricate(:post) }
    fab!(:bookmark) { Fabricate(:bookmark, user: user, post: post, topic: post.topic) }

    before do
      sign_in(user)
    end

    it "deletes the bookmark" do
      bookmark_id = bookmark.id
      delete "/posts/#{post.id}/bookmark.json"
      expect(Bookmark.find_by(id: bookmark_id)).to eq(nil)
    end

    context "when the user still has bookmarks in the topic" do
      before do
        Fabricate(:bookmark, user: user, post: Fabricate(:post, topic: post.topic), topic: topic)
      end
      it "marks topic_bookmaked as true" do
        delete "/posts/#{post.id}/bookmark.json"
        expect(JSON.parse(response.body)['topic_bookmarked']).to eq(true)
      end
    end
  end

  describe '#bookmark' do
    include_examples 'action requires login', :put, "/posts/2/bookmark.json"
    let!(:post) { post_by_user }

    describe 'when logged in' do
      before do
        sign_in(user)
      end

      fab!(:private_message) { Fabricate(:private_message_post) }

      it "raises an error if the user doesn't have permission to see the post" do
        put "/posts/#{private_message.id}/bookmark.json", params: { bookmarked: "true" }
        expect(response).to be_forbidden
      end

      it 'creates a bookmark' do
        put "/posts/#{post.id}/bookmark.json", params: { bookmarked: "true" }
        expect(response.status).to eq(200)

        post_action = PostAction.find_by(user: user, post: post)
        expect(post_action.post_action_type_id).to eq(PostActionType.types[:bookmark])
      end

      context "removing a bookmark" do
        let(:post_action) { PostActionCreator.create(user, post, :bookmark).post_action }

        it "returns the right response when post is not bookmarked" do
          put "/posts/#{post_by_user.id}/bookmark.json"
          expect(response.status).to eq(404)
        end

        it "should be able to remove a bookmark" do
          post_action
          put "/posts/#{post.id}/bookmark.json"

          expect(PostAction.find_by(id: post_action.id)).to eq(nil)
        end

        describe "when user doesn't have permission to see bookmarked post" do
          it "should still be able to remove a bookmark" do
            post_action
            post = post_action.post
            topic = post.topic
            topic.convert_to_private_message(admin)
            topic.remove_allowed_user(admin, user.username)

            expect(Guardian.new(user).can_see_post?(post.reload)).to eq(false)

            put "/posts/#{post.id}/bookmark.json"

            expect(PostAction.find_by(id: post_action.id)).to eq(nil)
          end
        end

        describe "when post has been deleted" do
          it "should still be able to remove a bookmark" do
            post = post_action.post
            post.trash!

            put "/posts/#{post.id}/bookmark.json"

            expect(PostAction.find_by(id: post_action.id)).to eq(nil)
          end
        end
      end
    end

    context "api" do
      let(:api_key) { Fabricate(:api_key, user: user) }
      let(:master_key) { Fabricate(:api_key, user: nil) }

      # choosing an arbitrarily easy to mock trusted activity
      it 'allows users with api key to bookmark posts' do
        put "/posts/#{post.id}/bookmark.json",
          params: { bookmarked: "true" },
          headers: { HTTP_API_KEY: api_key.key }

        expect(response.status).to eq(200)
        expect(PostAction.where(
          post: post,
          user: user,
          post_action_type_id: PostActionType.types[:bookmark]
        ).count).to eq(1)
      end

      it 'raises an error with a user key that does not match an optionally specified username' do
        put "/posts/#{post.id}/bookmark.json",
          params: { bookmarked: "true" },
          headers: { HTTP_API_KEY: api_key.key, HTTP_API_USERNAME: 'made_up' }

        expect(response.status).to eq(403)
      end

      it 'allows users with a master api key to bookmark posts' do
        put "/posts/#{post.id}/bookmark.json",
          params: { bookmarked: "true" },
          headers: { HTTP_API_KEY: master_key.key, HTTP_API_USERNAME: user.username }

        expect(response.status).to eq(200)
        expect(PostAction.where(
          post: post,
          user: user,
          post_action_type_id: PostActionType.types[:bookmark]
        ).count).to eq(1)
      end

      it 'disallows phonies to bookmark posts' do
        put "/posts/#{post.id}/bookmark.json",
          params: { bookmarked: "true" },
          headers: { HTTP_API_KEY: SecureRandom.hex(32), HTTP_API_USERNAME: user.username }

        expect(response.status).to eq(403)
      end

      it 'disallows blank api' do
        put "/posts/#{post.id}/bookmark.json",
          params: { bookmarked: "true" },
          headers: { HTTP_API_KEY: "", HTTP_API_USERNAME: user.username }

        expect(response.status).to eq(403)
      end
    end
  end

  describe '#wiki' do
    include_examples "action requires login", :put, "/posts/2/wiki.json"

    describe "when logged in" do
      before do
        sign_in(user)
      end

      let!(:post) { post_by_user }

      it "raises an error if the user doesn't have permission to wiki the post" do
        put "/posts/#{post.id}/wiki.json", params: { wiki: 'true' }
        expect(response).to be_forbidden
      end

      it "toggle wiki status should create a new version" do
        sign_in(admin)
        another_user = Fabricate(:user)
        another_post = Fabricate(:post, user: another_user)

        expect do
          put "/posts/#{another_post.id}/wiki.json", params: { wiki: 'true' }
        end.to change { another_post.reload.version }.by(1)

        expect do
          put "/posts/#{another_post.id}/wiki.json", params: { wiki: 'false' }
        end.to change { another_post.reload.version }.by(-1)

        sign_in(Fabricate(:admin))

        expect do
          put "/posts/#{another_post.id}/wiki.json", params: { wiki: 'true' }
        end.to change { another_post.reload.version }.by(1)
      end

      it "can wiki a post" do
        sign_in(admin)
        put "/posts/#{post.id}/wiki.json", params: { wiki: 'true' }

        post.reload
        expect(post.wiki).to eq(true)
      end

      it "can unwiki a post" do
        wikied_post = Fabricate(:post, user: user, wiki: true)
        sign_in(admin)

        put "/posts/#{wikied_post.id}/wiki.json", params: { wiki: 'false' }

        wikied_post.reload
        expect(wikied_post.wiki).to eq(false)
      end
    end
  end

  describe '#post_type' do
    include_examples "action requires login", :put, "/posts/2/post_type.json"

    describe "when logged in" do
      before do
        sign_in(user)
      end

      let!(:post) { post_by_user }

      it "raises an error if the user doesn't have permission to change the post type" do
        put "/posts/#{post.id}/post_type.json", params: { post_type: 2 }
        expect(response).to be_forbidden
      end

      it "can change the post type" do
        sign_in(moderator)
        put "/posts/#{post.id}/post_type.json", params: { post_type: 2 }

        post.reload
        expect(post.post_type).to eq(2)
      end
    end
  end

  describe '#rebake' do
    include_examples "action requires login", :put, "/posts/2/rebake.json"

    describe "when logged in" do
      let!(:post) { post_by_user }

      it "raises an error if the user doesn't have permission to rebake the post" do
        sign_in(user)
        put "/posts/#{post.id}/rebake.json"
        expect(response).to be_forbidden
      end

      it "can rebake the post" do
        sign_in(moderator)
        put "/posts/#{post.id}/rebake.json"
        expect(response.status).to eq(200)
      end

      it "will invalidate broken images cache" do
        sign_in(moderator)
        post.custom_fields[Post::BROKEN_IMAGES] = ["https://example.com/image.jpg"].to_json
        post.save_custom_fields
        put "/posts/#{post.id}/rebake.json"
        post.reload
        expect(post.custom_fields[Post::BROKEN_IMAGES]).to be_nil
      end
    end
  end

  describe '#create' do
    include_examples 'action requires login', :post, "/posts.json"

    before do
      SiteSetting.min_first_post_typing_time = 0
      SiteSetting.enable_whispers = true
    end

    context 'api' do
      it 'memoizes duplicate requests' do
        raw = "this is a test post 123 #{SecureRandom.hash}"
        title = "this is a title #{SecureRandom.hash}"

        master_key = Fabricate(:api_key).key

        post "/posts.json",
          params: { raw: raw, title: title, wpid: 1 },
          headers: { HTTP_API_USERNAME: user.username, HTTP_API_KEY: master_key }

        expect(response.status).to eq(200)
        original = response.body

        post "/posts.json",
          params: { raw: raw, title: title, wpid: 2 },
          headers: { HTTP_API_USERNAME: user.username_lower, HTTP_API_KEY: master_key }

        expect(response.status).to eq(200)
        expect(response.body).to eq(original)
      end

      it 'allows to create posts in import_mode' do
        Jobs.run_immediately!
        NotificationEmailer.enable
        post_1 = Fabricate(:post)
        master_key = Fabricate(:api_key).key

        post "/posts.json",
          params: { raw: 'this is test reply 1', topic_id: post_1.topic.id, reply_to_post_number: 1 },
          headers: { HTTP_API_USERNAME: user.username, HTTP_API_KEY: master_key }

        expect(response.status).to eq(200)
        expect(post_1.topic.user.notifications.count).to eq(1)
        post_1.topic.user.notifications.destroy_all

        post "/posts.json",
          params: { raw: 'this is test reply 2', topic_id: post_1.topic.id, reply_to_post_number: 1, import_mode: true },
          headers: { HTTP_API_USERNAME: user.username, HTTP_API_KEY: master_key }

        expect(response.status).to eq(200)
        expect(post_1.topic.user.notifications.count).to eq(0)

        post "/posts.json",
          params: { raw: 'this is test reply 3', topic_id: post_1.topic.id, reply_to_post_number: 1, import_mode: false },
          headers: { HTTP_API_USERNAME: user.username, HTTP_API_KEY: master_key }

        expect(response.status).to eq(200)
        expect(post_1.topic.user.notifications.count).to eq(1)
      end

      it 'prevents whispers for regular users' do
        post_1 = Fabricate(:post)
        user_key = ApiKey.create!(user: user).key

        post "/posts.json",
          params: { raw: 'this is test whisper', topic_id: post_1.topic.id, reply_to_post_number: 1, whisper: true },
          headers: { HTTP_API_USERNAME: user.username, HTTP_API_KEY: user_key }

        expect(response.status).to eq(403)
      end

      it 'will raise an error if specified category cannot be found' do
        user = Fabricate(:admin)
        master_key = Fabricate(:api_key).key

        post "/posts.json",
          params: { title: 'this is a test title', raw: 'this is test body', category: 'invalid' },
          headers: { HTTP_API_USERNAME: user.username, HTTP_API_KEY: master_key }

        expect(response.status).to eq(400)

        expect(JSON.parse(response.body)["errors"]).to include(
          I18n.t("invalid_params", message: "category")
        )
      end
    end

    describe "when logged in" do
      before do
        sign_in(user)
      end

      context "fast typing" do
        before do
          SiteSetting.min_first_post_typing_time = 3000
          SiteSetting.auto_silence_fast_typers_max_trust_level = 1
        end

        it 'queues the post if min_first_post_typing_time is not met' do
          post "/posts.json", params: {
            raw: 'this is the test content',
            title: 'this is the test title for the topic',
            composer_open_duration_msecs: 204,
            typing_duration_msecs: 100,
            reply_to_post_number: 123
          }

          expect(response.status).to eq(200)
          parsed = ::JSON.parse(response.body)

          expect(parsed["action"]).to eq("enqueued")

          user.reload
          expect(user).to be_silenced

          rp = ReviewableQueuedPost.find_by(created_by: user)
          expect(rp.payload['typing_duration_msecs']).to eq(100)
          expect(rp.payload['composer_open_duration_msecs']).to eq(204)
          expect(rp.payload['reply_to_post_number']).to eq(123)
          expect(rp.reviewable_scores.first.reason).to eq('fast_typer')

          expect(parsed['pending_post']).to be_present
          expect(parsed['pending_post']['id']).to eq(rp.id)
          expect(parsed['pending_post']['raw']).to eq("this is the test content")

          mod = moderator
          rp.perform(mod, :approve_post)

          user.reload
          expect(user).not_to be_silenced
        end

        it "doesn't enqueue posts when user first creates a topic" do
          user.user_stat.update_column(:topic_count, 1)

          Draft.set(user, "should_clear", 0, "{'a' : 'b'}")

          post "/posts.json", params: {
            raw: 'this is the test content',
            title: 'this is the test title for the topic',
            composer_open_duration_msecs: 204,
            typing_duration_msecs: 100,
            topic_id: topic.id,
            draft_key: "should_clear"
          }

          expect(response.status).to eq(200)
          parsed = ::JSON.parse(response.body)

          expect(parsed["action"]).not_to be_present

          expect {
            Draft.get(user, "should_clear", 0)
          }.to raise_error(Draft::OutOfSequence)
        end

        it "doesn't enqueue replies when the topic is closed" do
          topic = Fabricate(:closed_topic)

          post "/posts.json", params: {
            raw: 'this is the test content',
            title: 'this is the test title for the topic',
            topic_id: topic.id
          }

          expect(response).not_to be_successful
          parsed = ::JSON.parse(response.body)
          expect(parsed["action"]).not_to eq("enqueued")
        end

        it "doesn't enqueue replies when the post is too long" do
          SiteSetting.max_post_length = 10

          post "/posts.json", params: {
            raw: 'this is the test content',
            title: 'this is the test title for the topic'
          }

          expect(response).not_to be_successful
          parsed = ::JSON.parse(response.body)
          expect(parsed["action"]).not_to eq("enqueued")
        end
      end

      it 'silences correctly based on auto_silence_first_post_regex' do
        SiteSetting.auto_silence_first_post_regex = "I love candy|i eat s[1-5]"

        post "/posts.json", params: {
          raw: 'this is the test content',
          title: 'when I eat s3 sometimes when not looking'
        }

        expect(response.status).to eq(200)
        parsed = ::JSON.parse(response.body)

        expect(parsed["action"]).to eq("enqueued")
        reviewable = ReviewableQueuedPost.find_by(created_by: user)
        score = reviewable.reviewable_scores.first
        expect(score.reason).to eq('auto_silence_regex')

        user.reload
        expect(user).to be_silenced
      end

      it "can send a message to a group" do
        group = Group.create(name: 'test_group', messageable_level: Group::ALIAS_LEVELS[:nobody])
        user1 = user
        group.add(user1)

        post "/posts.json", params: {
          raw: 'I can haz a test',
          title: 'I loves my test',
          target_recipients: group.name,
          archetype: Archetype.private_message
        }

        expect(response).not_to be_successful

        # allow pm to this group
        group.update_columns(messageable_level: Group::ALIAS_LEVELS[:everyone])

        post "/posts.json", params: {
          raw: 'I can haz a test',
          title: 'I loves my test',
          target_recipients: group.name,
          archetype: Archetype.private_message
        }

        expect(response.status).to eq(200)

        parsed = ::JSON.parse(response.body)
        post = Post.find(parsed['id'])

        expect(post.topic.topic_allowed_users.length).to eq(1)
        expect(post.topic.topic_allowed_groups.length).to eq(1)
      end

      it "returns the nested post with a param" do
        post "/posts.json", params: {
          raw: 'this is the test content',
          title: 'this is the test title for the topic',
          nested_post: true
        }

        expect(response.status).to eq(200)
        parsed = ::JSON.parse(response.body)
        expect(parsed['post']).to be_present
        expect(parsed['post']['cooked']).to be_present
      end

      it 'protects against dupes' do
        raw = "this is a test post 123 #{SecureRandom.hash}"
        title = "this is a title #{SecureRandom.hash}"

        expect do
          post "/posts.json", params: { raw: raw, title: title, wpid: 1 }
        end.to change { Post.count }

        expect(response.status).to eq(200)

        expect do
          post "/posts.json", params: { raw: raw, title: title, wpid: 2 }
        end.to_not change { Post.count }

        expect(response.status).to eq(422)
      end

      it 'can not create a post in a disallowed category' do
        category.set_permissions(staff: :full)
        category.save!

        post "/posts.json", params: {
          raw: 'this is the test content',
          title: 'this is the test title for the topic',
          category: category.id,
          meta_data: { xyz: 'abc' }
        }

        expect(response.status).to eq(403)
      end

      it 'can not create a post with a tag that is restricted' do
        SiteSetting.tagging_enabled = true
        tag = Fabricate(:tag)
        category.allowed_tags = [tag.name]
        category.save!

        post "/posts.json", params: {
          raw: 'this is the test content',
          title: 'this is the test title for the topic',
          tags: [tag.name],
        }

        expect(response.status).to eq(422)
        json = JSON.parse(response.body)
        expect(json['errors']).to be_present
      end

      it 'creates the post' do
        post "/posts.json", params: {
          raw: 'this is the test content',
          title: 'this is the test title for the topic',
          category: category.id,
          meta_data: { xyz: 'abc' }
        }

        expect(response.status).to eq(200)

        new_post = Post.last
        topic = new_post.topic

        expect(new_post.user).to eq(user)
        expect(new_post.raw).to eq('this is the test content')
        expect(topic.title).to eq('This is the test title for the topic')
        expect(topic.category).to eq(category)
        expect(topic.meta_data).to eq("xyz" => 'abc')
      end

      it 'can create an uncategorized topic' do
        title = 'this is the test title for the topic'

        expect do
          post "/posts.json", params: {
            raw: 'this is the test content',
            title: title,
            category: ""
          }

          expect(response.status).to eq(200)
        end.to change { Topic.count }.by(1)

        topic = Topic.last

        expect(topic.title).to eq(title.capitalize)
        expect(topic.category_id).to eq(SiteSetting.uncategorized_category_id)
      end

      it 'can create a reply to a post' do
        topic = Fabricate(:private_message_post, user: user).topic
        post_2 = Fabricate(:private_message_post, user: user, topic: topic)

        post "/posts.json", params: {
          raw: 'this is the test content',
          topic_id: topic.id,
          reply_to_post_number: post_2.post_number,
          image_sizes: { width: '100', height: '200' }
        }

        expect(response.status).to eq(200)

        new_post = Post.last
        topic = new_post.topic

        expect(new_post.user).to eq(user)
        expect(new_post.raw).to eq('this is the test content')
        expect(new_post.reply_to_post_number).to eq(post_2.post_number)

        job_args = Jobs::ProcessPost.jobs.first["args"].first

        expect(job_args["image_sizes"]).to eq("width" => '100', "height" => '200')
      end

      it 'creates a private post' do
        user_2 = Fabricate(:user)
        user_3 = Fabricate(:user)

        post "/posts.json", params: {
          raw: 'this is the test content',
          archetype: 'private_message',
          title: "this is some post",
          target_recipients: "#{user_2.username},#{user_3.username}"
        }

        expect(response.status).to eq(200)

        new_post = Post.last
        new_topic = Topic.last

        expect(new_post.user).to eq(user)
        expect(new_topic.private_message?).to eq(true)
        expect(new_topic.allowed_users).to contain_exactly(user, user_2, user_3)
      end

      context "when target_recipients not provided" do
        it "errors when creating a private post" do
          post "/posts.json", params: {
            raw: 'this is the test content',
            archetype: 'private_message',
            title: "this is some post",
            target_recipients: ""
          }

          expect(response.status).to eq(422)
          expect(JSON.parse(response.body)["errors"]).to include(
            I18n.t("activerecord.errors.models.topic.attributes.base.no_user_selected")
          )
        end
      end

      context "when topic_id is set" do
        fab!(:topic) { Fabricate(:topic) }

        it "errors when creating a private post" do
          user_2 = Fabricate(:user)

          post "/posts.json", params: {
            raw: 'this is the test content',
            archetype: 'private_message',
            title: "this is some post",
            target_recipients: user_2.username,
            topic_id: topic.id
          }

          expect(response.status).to eq(422)
          expect(JSON.parse(response.body)["errors"]).to include(
            I18n.t("create_pm_on_existing_topic")
          )
        end
      end

      context "errors" do
        it "does not succeed" do
          post "/posts.json", params: { raw: 'test' }
          expect(response).not_to be_successful
          expect(response.status).to eq(422)
        end

        it "it triggers flag_linked_posts_as_spam when the post creator returns spam" do
          SiteSetting.newuser_spam_host_threshold = 1
          sign_in(Fabricate(:user, trust_level: 0))

          post "/posts.json", params: {
            raw: 'this is the test content http://fakespamwebsite.com http://fakespamwebsite.com/spam http://fakespamwebsite.com/spammy',
            title: 'this is the test title for the topic',
            meta_data: { xyz: 'abc' }
          }

          expect(JSON.parse(response.body)["errors"]).to include(I18n.t(:spamming_host))
        end

        context "allow_uncategorized_topics is false" do
          before do
            SiteSetting.allow_uncategorized_topics = false
          end

          it "cant create an uncategorized post" do
            post "/posts.json", params: {
              raw: "a new post with no category",
              title: "a new post with no category"
            }
            expect(response).not_to be_successful
          end

          context "as staff" do
            before do
              sign_in(admin)
            end

            it "cant create an uncategorized post" do
              post "/posts.json", params: {
                raw: "a new post with no category",
                title: "a new post with no category"
              }
              expect(response).not_to be_successful
            end
          end
        end
      end
    end

    describe 'shared draft' do
      fab!(:destination_category) { Fabricate(:category) }

      it "will raise an error for regular users" do
        post "/posts.json", params: {
          raw: 'this is the shared draft content',
          title: "this is the shared draft title",
          category: destination_category.id,
          shared_draft: 'true'
        }
        expect(response).not_to be_successful
      end

      describe "as a staff user" do
        before do
          sign_in(moderator)
        end

        it "will raise an error if there is no shared draft category" do
          post "/posts.json", params: {
            raw: 'this is the shared draft content',
            title: "this is the shared draft title",
            category: destination_category.id,
            shared_draft: 'true'
          }
          expect(response).not_to be_successful
        end

        context "with a shared category" do
          fab!(:shared_category) { Fabricate(:category) }
          before do
            SiteSetting.shared_drafts_category = shared_category.id
          end

          it "will work if the shared draft category is present" do
            post "/posts.json", params: {
              raw: 'this is the shared draft content',
              title: "this is the shared draft title",
              category: destination_category.id,
              shared_draft: 'true'
            }
            expect(response.status).to eq(200)
            result = JSON.parse(response.body)
            topic = Topic.find(result['topic_id'])
            expect(topic.category_id).to eq(shared_category.id)
            expect(topic.shared_draft.category_id).to eq(destination_category.id)
          end
        end
      end
    end

    describe 'warnings' do
      fab!(:user_2) { Fabricate(:user) }

      context 'as a staff user' do
        before do
          sign_in(admin)
        end

        it 'should be able to mark a topic as warning' do
          post "/posts.json", params: {
            raw: 'this is the test content',
            archetype: 'private_message',
            title: "this is some post",
            target_recipients: user_2.username,
            is_warning: true
          }

          expect(response.status).to eq(200)

          new_topic = Topic.last

          expect(new_topic.title).to eq('This is some post')
          expect(new_topic.is_official_warning?).to eq(true)
        end

        it 'should be able to mark a topic as not a warning' do
          post "/posts.json", params: {
            raw: 'this is the test content',
            archetype: 'private_message',
            title: "this is some post",
            target_recipients: user_2.username,
            is_warning: false
          }

          expect(response.status).to eq(200)

          new_topic = Topic.last

          expect(new_topic.title).to eq('This is some post')
          expect(new_topic.is_official_warning?).to eq(false)
        end
      end

      context 'as a normal user' do
        it 'should not be able to mark a topic as warning' do
          sign_in(user)
          post "/posts.json", params: {
            raw: 'this is the test content',
            archetype: 'private_message',
            title: "this is some post",
            target_recipients: user_2.username,
            is_warning: true
          }

          expect(response.status).to eq(200)

          new_topic = Topic.last

          expect(new_topic.title).to eq('This is some post')
          expect(new_topic.is_official_warning?).to eq(false)
        end
      end
    end

    context "topic bump" do
      shared_examples "it works" do
        it "should be able to skip topic bumping" do
          original_bumped_at = 1.day.ago
          topic = Fabricate(:topic, bumped_at: original_bumped_at)

          post "/posts.json", params: {
            raw: 'this is the test content',
            topic_id: topic.id,
            no_bump: true
          }

          expect(response.status).to eq(200)
          expect(topic.reload.bumped_at).to eq_time(original_bumped_at)
        end

        it "should be able to post with topic bumping" do
          post "/posts.json", params: {
            raw: 'this is the test content',
            topic_id: topic.id
          }

          expect(response.status).to eq(200)
          expect(topic.reload.bumped_at).to eq_time(topic.posts.last.created_at)
        end
      end

      context "admins" do
        before do
          sign_in(admin)
        end

        include_examples "it works"
      end

      context "moderators" do
        before do
          sign_in(moderator)
        end

        include_examples "it works"
      end

      context "TL4 users" do
        fab!(:trust_level_4) { Fabricate(:trust_level_4) }

        before do
          sign_in(trust_level_4)
        end

        include_examples "it works"
      end

      context "users" do
        fab!(:topic) { Fabricate(:topic) }

        [:user].each do |user|
          it "will raise an error for #{user}" do
            sign_in(Fabricate(user))
            post "/posts.json", params: {
              raw: 'this is the test content',
              topic_id: topic.id,
              no_bump: true
            }
            expect(response.status).to eq(400)
          end
        end
      end
    end

  end

  describe '#revisions' do
    fab!(:post) { Fabricate(:post, version: 2) }
    let(:post_revision) { Fabricate(:post_revision, post: post) }

    it "throws an exception when revision is < 2" do
      get "/posts/#{post.id}/revisions/1.json"
      expect(response.status).to eq(400)
    end

    context "when edit history is not visible to the public" do

      before { SiteSetting.edit_history_visible_to_public = false }

      it "ensures anonymous cannot see the revisions" do
        get "/posts/#{post.id}/revisions/#{post_revision.number}.json"
        expect(response).to be_forbidden
      end

      it "ensures regular user cannot see the revisions" do
        sign_in(user)
        get "/posts/#{post.id}/revisions/#{post_revision.number}.json"
        expect(response).to be_forbidden
      end

      it "ensures staff can see the revisions" do
        sign_in(admin)
        get "/posts/#{post.id}/revisions/#{post_revision.number}.json"
        expect(response.status).to eq(200)
      end

      it "ensures poster can see the revisions" do
        user = Fabricate(:active_user)
        sign_in(user)

        post = Fabricate(:post, user: user, version: 3)
        pr = Fabricate(:post_revision, user: user, post: post)

        get "/posts/#{pr.post_id}/revisions/#{pr.number}.json"
        expect(response.status).to eq(200)
      end

      it "ensures trust level 4 can see the revisions" do
        sign_in(Fabricate(:user, trust_level: 4))
        get "/posts/#{post_revision.post_id}/revisions/#{post_revision.number}.json"
        expect(response.status).to eq(200)
      end
    end

    context "when post is hidden" do
      before {
        post.hidden = true
        post.save
      }

      it "throws an exception for users" do
        sign_in(user)
        get "/posts/#{post.id}/revisions/#{post_revision.number}.json"
        expect(response.status).to eq(404)
      end

      it "works for admins" do
        sign_in(admin)
        get "/posts/#{post.id}/revisions/#{post_revision.number}.json"
        expect(response.status).to eq(200)
      end
    end

    context "when edit history is visible to everyone" do

      before { SiteSetting.edit_history_visible_to_public = true }

      it "ensures anyone can see the revisions" do
        get "/posts/#{post_revision.post_id}/revisions/#{post_revision.number}.json"
        expect(response.status).to eq(200)
      end
    end

    context "deleted post" do
      fab!(:deleted_post) { Fabricate(:post, user: admin, version: 3) }
      fab!(:deleted_post_revision) { Fabricate(:post_revision, user: admin, post: deleted_post) }

      before { deleted_post.trash!(admin) }

      it "also work on deleted post" do
        sign_in(admin)
        get "/posts/#{deleted_post_revision.post_id}/revisions/#{deleted_post_revision.number}.json"
        expect(response.status).to eq(200)
      end
    end

    context "deleted topic" do
      fab!(:deleted_topic) { Fabricate(:topic, user: admin) }
      fab!(:post) { Fabricate(:post, user: admin, topic: deleted_topic, version: 3) }
      fab!(:post_revision) { Fabricate(:post_revision, user: admin, post: post) }

      before { deleted_topic.trash!(admin) }

      it "also work on deleted topic" do
        sign_in(admin)
        get "/posts/#{post_revision.post_id}/revisions/#{post_revision.number}.json"
        expect(response.status).to eq(200)
      end
    end
  end

  describe '#revert' do
    include_examples 'action requires login', :put, "/posts/123/revisions/2/revert.json"

    fab!(:post) { Fabricate(:post, user: Fabricate(:user), raw: "Lorem ipsum dolor sit amet, cu nam libris tractatos, ancillae senserit ius ex") }
    let(:post_revision) { Fabricate(:post_revision, post: post, modifications: { "raw" => ["this is original post body.", "this is edited post body."] }) }
    let(:blank_post_revision) { Fabricate(:post_revision, post: post, modifications: { "edit_reason" => ["edit reason #1", "edit reason #2"] }) }
    let(:same_post_revision) { Fabricate(:post_revision, post: post, modifications: { "raw" => ["Lorem ipsum dolor sit amet, cu nam libris tractatos, ancillae senserit ius ex", "this is edited post body."] }) }

    let(:post_id) { post.id }
    let(:revision_id) { post_revision.number }

    describe 'when logged in as a regular user' do
      it "does not work" do
        sign_in(user)
        put "/posts/#{post_id}/revisions/#{revision_id}/revert.json"
        expect(response).to_not be_successful
      end
    end

    describe "when logged in as staff" do
      before do
        sign_in(moderator)
      end

      it "fails when revision is < 2" do
        put "/posts/#{post_id}/revisions/1/revert.json"
        expect(response.status).to eq(400)
      end

      it "fails when post_revision record is not found" do
        put "/posts/#{post_id}/revisions/#{revision_id + 1}/revert.json"
        expect(response).to_not be_successful
      end

      it "fails when post record is not found" do
        put "/posts/#{post_id + 1}/revisions/#{revision_id}/revert.json"
        expect(response).to_not be_successful
      end

      it "fails when revision is blank" do
        put "/posts/#{post_id}/revisions/#{blank_post_revision.number}/revert.json"
        expect(response.status).to eq(422)
        expect(JSON.parse(response.body)['errors']).to include(I18n.t('revert_version_same'))
      end

      it "fails when revised version is same as current version" do
        put "/posts/#{post_id}/revisions/#{same_post_revision.number}/revert.json"
        expect(response.status).to eq(422)
        expect(JSON.parse(response.body)['errors']).to include(I18n.t('revert_version_same'))
      end

      it "works!" do
        put "/posts/#{post_id}/revisions/#{revision_id}/revert.json"
        expect(response.status).to eq(200)
      end

      it "supports reverting posts in deleted topics" do
        first_post = post.topic.ordered_posts.first
        PostDestroyer.new(moderator, first_post).destroy

        put "/posts/#{post_id}/revisions/#{revision_id}/revert.json"
        expect(response.status).to eq(200)
      end
    end
  end

  describe '#expand_embed' do
    before do
      sign_in(user)
    end

    fab!(:post) { Fabricate(:post) }

    it "raises an error when you can't see the post" do
      post = Fabricate(:private_message_post)
      get "/posts/#{post.id}/expand-embed.json"
      expect(response).not_to be_successful
    end

    it "retrieves the body when you can see the post" do
      TopicEmbed.expects(:expanded_for).with(post).returns("full content")
      get "/posts/#{post.id}/expand-embed.json"
      expect(response.status).to eq(200)
      expect(::JSON.parse(response.body)['cooked']).to eq("full content")
    end
  end

  describe '#flagged_posts' do
    include_examples "action requires login", :get, "/posts/system/flagged.json"

    describe "when logged in" do
      it "raises an error if the user doesn't have permission to see the flagged posts" do
        sign_in(user)
        get "/posts/system/flagged.json"
        expect(response).to be_forbidden
      end

      it "can see the flagged posts when authorized" do
        sign_in(moderator)
        get "/posts/system/flagged.json"
        expect(response.status).to eq(200)
      end

      it "only shows agreed and deferred flags" do
        post_agreed = create_post(user: user)
        post_deferred = create_post(user: user)
        post_disagreed = create_post(user: user)

        r0 = PostActionCreator.spam(moderator, post_agreed).reviewable
        r1 = PostActionCreator.off_topic(moderator, post_deferred).reviewable
        r2 = PostActionCreator.inappropriate(moderator, post_disagreed).reviewable

        r0.perform(admin, :agree_and_keep)
        r1.perform(admin, :ignore)
        r2.perform(admin, :disagree)

        sign_in(Fabricate(:moderator))
        get "/posts/#{user.username}/flagged.json"
        expect(response.status).to eq(200)

        expect(JSON.parse(response.body).length).to eq(2)
      end
    end
  end

  describe '#deleted_posts' do
    include_examples "action requires login", :get, "/posts/system/deleted.json"

    describe "when logged in" do
      it "raises an error if the user doesn't have permission to see the deleted posts" do
        sign_in(user)
        get "/posts/system/deleted.json"
        expect(response).to be_forbidden
      end

      it "can see the deleted posts when authorized" do
        sign_in(moderator)
        get "/posts/system/deleted.json"
        expect(response.status).to eq(200)
      end

      it "doesn't return secured categories for moderators if they don't have access" do
        Fabricate(:moderator)

        group = Fabricate(:group)
        group.add_owner(user)

        secured_category = Fabricate(:private_category, group: group)
        secured_post = create_post(user: user, category: secured_category)
        PostDestroyer.new(admin, secured_post).destroy

        sign_in(moderator)
        get "/posts/#{user.username}/deleted.json"
        expect(response.status).to eq(200)

        data = JSON.parse(response.body)
        expect(data.length).to eq(0)
      end

      it "doesn't return PMs for moderators" do
        Fabricate(:moderator)

        pm_post = create_post(user: user, archetype: 'private_message', target_usernames: [admin.username])
        PostDestroyer.new(admin, pm_post).destroy

        sign_in(moderator)
        get "/posts/#{user.username}/deleted.json"
        expect(response.status).to eq(200)

        data = JSON.parse(response.body)
        expect(data.length).to eq(0)
      end

      it "only shows posts deleted by other users" do
        create_post(user: user)
        post_deleted_by_user = create_post(user: user)
        post_deleted_by_admin = create_post(user: user)

        PostDestroyer.new(user, post_deleted_by_user).destroy
        PostDestroyer.new(admin, post_deleted_by_admin).destroy

        sign_in(admin)
        get "/posts/#{user.username}/deleted.json"
        expect(response.status).to eq(200)

        data = JSON.parse(response.body)
        expect(data.length).to eq(1)
        expect(data[0]["id"]).to eq(post_deleted_by_admin.id)
        expect(data[0]["deleted_by"]["id"]).to eq(admin.id)
      end
    end
  end

  describe '#markdown_id' do
    it "can be viewed by anonymous" do
      post = Fabricate(:post, raw: "123456789")
      get "/posts/#{post.id}/raw.json"
      expect(response.status).to eq(200)
      expect(response.body).to eq("123456789")
    end
  end

  describe '#markdown_num' do
    it "can be viewed by anonymous" do
      topic = Fabricate(:topic)
      post = Fabricate(:post, topic: topic, post_number: 1, raw: "123456789")
      post.save
      get "/raw/#{topic.id}/1.json"
      expect(response.status).to eq(200)
      expect(response.body).to eq("123456789")
    end
  end

  describe '#short_link' do
    fab!(:topic) { Fabricate(:topic) }
    fab!(:post) { Fabricate(:post, topic: topic) }

    it "redirects to the topic" do
      get "/p/#{post.id}.json"
      expect(response).to be_redirect
    end

    it "returns a 403 when access is denied" do
      post = Fabricate(:private_message_post)
      get "/p/#{post.id}.json"
      expect(response).to be_forbidden
    end
  end

  describe '#user_posts_feed' do
    it 'returns public posts rss feed' do
      public_post
      private_post

      get "/u/#{user.username}/activity.rss"

      expect(response.status).to eq(200)

      body = response.body

      expect(body).to_not include(private_post.url)
      expect(body).to include(public_post.url)
    end

    it 'returns public posts as JSON' do
      public_post
      private_post

      get "/u/#{user.username}/activity.json"

      expect(response.status).to eq(200)

      body = response.body

      expect(body).to_not include(private_post.topic.slug)
      expect(body).to include(public_post.topic.slug)
    end
  end

  describe '#latest' do
    context 'private posts' do
      describe 'when not logged in' do
        it 'should return the right response' do
          Fabricate(:post)

          get "/private-posts.rss"

          expect(response.status).to eq(404)

          expect(response.body).to have_tag(
            "input", with: { value: "private_posts" }
          )
        end
      end

      it 'returns private posts rss feed' do
        sign_in(admin)

        public_post
        private_post
        get "/private-posts.rss"

        expect(response.status).to eq(200)

        body = response.body

        expect(body).to include(private_post.url)
        expect(body).to_not include(public_post.url)
      end

      it 'returns private posts for json' do
        sign_in(admin)

        public_post
        private_post
        get "/private-posts.json"
        expect(response.status).to eq(200)

        json = ::JSON.parse(response.body)
        post_ids = json['private_posts'].map { |p| p['id'] }

        expect(post_ids).to include private_post.id
        expect(post_ids).to_not include public_post.id
      end
    end

    context 'public posts' do
      it 'returns public posts with topic rss feed' do
        public_post
        private_post

        get "/posts.rss"

        expect(response.status).to eq(200)

        body = response.body

        expect(body).to include(public_post.url)
        expect(body).to_not include(private_post.url)
      end

      it 'returns public posts with topic for json' do
        topicless_post.update topic_id: -100

        public_post
        private_post
        topicless_post

        get "/posts.json"
        expect(response.status).to eq(200)

        json = ::JSON.parse(response.body)
        post_ids = json['latest_posts'].map { |p| p['id'] }

        expect(post_ids).to include public_post.id
        expect(post_ids).to_not include private_post.id
        expect(post_ids).to_not include topicless_post.id
      end
    end
  end

  describe '#cooked' do
    it 'returns the cooked conent' do
      post = Fabricate(:post, cooked: "WAt")
      get "/posts/#{post.id}/cooked.json"

      expect(response.status).to eq(200)
      json = ::JSON.parse(response.body)

      expect(json).to be_present
      expect(json['cooked']).to eq('WAt')
    end
  end

  describe '#raw_email' do
    include_examples "action requires login", :get, "/posts/2/raw-email.json"

    describe "when logged in" do
      let(:post) { Fabricate(:post, deleted_at: 2.hours.ago, user: Fabricate(:user), raw_email: 'email_content') }

      it "raises an error if the user doesn't have permission to view raw email" do
        sign_in(user)

        get "/posts/#{post.id}/raw-email.json"
        expect(response).to be_forbidden
      end

      it "can view raw email" do
        sign_in(moderator)

        get "/posts/#{post.id}/raw-email.json"
        expect(response.status).to eq(200)

        json = ::JSON.parse(response.body)
        expect(json['raw_email']).to eq('email_content')
      end
    end
  end

  describe "#locked" do
    before do
      sign_in(moderator)
    end

    it 'can lock and unlock the post' do
      put "/posts/#{public_post.id}/locked.json", params: { locked: "true" }
      expect(response.status).to eq(200)
      public_post.reload
      expect(public_post).to be_locked

      put "/posts/#{public_post.id}/locked.json", params: { locked: "false" }
      expect(response.status).to eq(200)
      public_post.reload
      expect(public_post).not_to be_locked
    end
  end

  describe "#notice" do
    before do
      sign_in(moderator)
    end

    it 'can create and remove notices' do
      put "/posts/#{public_post.id}/notice.json", params: { notice: "Hello *world*!\n\nhttps://github.com/discourse/discourse" }

      expect(response.status).to eq(200)
      public_post.reload
      expect(public_post.custom_fields[Post::NOTICE_TYPE]).to eq(Post.notices[:custom])
      expect(public_post.custom_fields[Post::NOTICE_ARGS]).to include('<p>Hello <em>world</em>!</p>')
      expect(public_post.custom_fields[Post::NOTICE_ARGS]).not_to include('onebox')

      put "/posts/#{public_post.id}/notice.json", params: { notice: nil }

      expect(response.status).to eq(200)
      public_post.reload
      expect(public_post.custom_fields[Post::NOTICE_TYPE]).to eq(nil)
      expect(public_post.custom_fields[Post::NOTICE_ARGS]).to eq(nil)
    end
  end

  describe Plugin::Instance do
    describe '#add_permitted_post_create_param' do
      fab!(:user) { Fabricate(:user) }
      let(:instance) { Plugin::Instance.new }
      let(:request) do
        Proc.new {
          post "/posts.json", params: {
            raw: 'this is the test content',
            title: 'this is the test title for the topic',
            composer_open_duration_msecs: 204,
            typing_duration_msecs: 100,
            reply_to_post_number: 123,
            string_arg: '123',
            hash_arg: { key1: 'val' },
            array_arg: ['1', '2', '3']
          }
        }
      end

      before do
        sign_in(user)
        SiteSetting.min_first_post_typing_time = 0
      end

      it 'allows strings to be added' do
        request.call
        expect(@controller.send(:create_params)).not_to include(string_arg: '123')

        instance.add_permitted_post_create_param(:string_arg)
        request.call
        expect(@controller.send(:create_params)).to include(string_arg: '123')
      end

      it 'allows hashes to be added' do
        instance.add_permitted_post_create_param(:hash_arg)
        request.call
        expect(@controller.send(:create_params)).not_to include(hash_arg: { key1: 'val' })

        instance.add_permitted_post_create_param(:hash_arg, :hash)
        request.call
        expect(@controller.send(:create_params)).to include(hash_arg: { key1: 'val' })
      end

      it 'allows strings to be added' do
        instance.add_permitted_post_create_param(:array_arg)
        request.call
        expect(@controller.send(:create_params)).not_to include(array_arg: ['1', '2', '3'])

        instance.add_permitted_post_create_param(:array_arg, :array)
        request.call
        expect(@controller.send(:create_params)).to include(array_arg: ['1', '2', '3'])
      end

    end
  end
end

import selectKit from "helpers/select-kit-helper";
import { acceptance } from "helpers/qunit-helpers";
import pretender from "helpers/create-pretender";

let groupArgs = {
  settings: {
    enable_group_directory: true
  },
  pretend(pretenderServer, helper) {
    pretenderServer.post("/groups/Macdonald/request_membership", () => {
      return helper.response({
        relative_url: "/t/internationalization-localization/280"
      });
    });
  }
};

acceptance("Group", groupArgs);

const response = object => {
  return [200, { "Content-Type": "application/json" }, object];
};

QUnit.test("Anonymous Viewing Group", async assert => {
  await visit("/g/discourse");

  assert.equal(
    count(".nav-pills li a[title='Messages']"),
    0,
    "it deos not show group messages navigation link"
  );

  await click(".nav-pills li a[title='Activity']");

  assert.ok(count(".user-stream-item") > 0, "it lists stream items");

  await click(".activity-nav li a[href='/g/discourse/activity/topics']");

  assert.ok(find(".topic-list"), "it shows the topic list");
  assert.equal(count(".topic-list-item"), 2, "it lists stream items");

  await click(".activity-nav li a[href='/g/discourse/activity/mentions']");

  assert.ok(count(".user-stream-item") > 0, "it lists stream items");
  assert.ok(
    find(".nav-pills li a[title='Edit Group']").length === 0,
    "it should not show messages tab if user is not admin"
  );
  assert.ok(
    find(".nav-pills li a[title='Logs']").length === 0,
    "it should not show Logs tab if user is not admin"
  );
  assert.ok(count(".user-stream-item") > 0, "it lists stream items");

  const groupDropdown = selectKit(".group-dropdown");
  await groupDropdown.expand();

  assert.equal(groupDropdown.rowByIndex(1).name(), "discourse");

  assert.equal(
    groupDropdown.rowByIndex(0).name(),
    I18n.t("groups.index.all").toLowerCase()
  );

  Discourse.SiteSettings.enable_group_directory = false;

  await visit("/g");
  await visit("/g/discourse");

  await groupDropdown.expand();

  assert.equal(
    find(".group-dropdown-filter").length,
    0,
    "it should not display the default header"
  );
});

QUnit.test("Anonymous Viewing Automatic Group", async assert => {
  await visit("/g/moderators");

  assert.equal(
    count(".nav-pills li a[title='Manage']"),
    0,
    "it deos not show group messages navigation link"
  );
});

acceptance("Group", Object.assign({ loggedIn: true }, groupArgs));

QUnit.test("User Viewing Group", async assert => {
  await visit("/g");
  await click(".group-index-request");

  assert.equal(
    find(".modal-header")
      .text()
      .trim(),
    I18n.t("groups.membership_request.title", { group_name: "Macdonald" })
  );

  assert.equal(
    find(".request-group-membership-form textarea").val(),
    "Please add me"
  );

  await click(".modal-footer .btn-primary");

  assert.equal(
    find(".fancy-title")
      .text()
      .trim(),
    "Internationalization / localization"
  );

  await visit("/g/discourse");

  await click(".group-message-button");

  assert.ok(count("#reply-control") === 1, "it opens the composer");
  assert.equal(
    find(".ac-wrap .item").text(),
    "discourse",
    "it prefills the group name"
  );
});

QUnit.test(
  "Admin viewing group messages when there are no messages",
  async assert => {
    pretender.get(
      "/topics/private-messages-group/eviltrout/discourse.json",
      () => {
        return response({ topic_list: { topics: [] } });
      }
    );

    await visit("/g/discourse");
    await click(".nav-pills li a[title='Messages']");

    assert.equal(
      find(".alert")
        .text()
        .trim(),
      I18n.t("choose_topic.none_found"),
      "it should display the right alert"
    );
  }
);

QUnit.test("Admin viewing group messages", async assert => {
  pretender.get(
    "/topics/private-messages-group/eviltrout/discourse.json",
    () => {
      return response({
        users: [
          {
            id: 2,
            username: "bruce1",
            avatar_template:
              "/user_avatar/meta.discourse.org/bruce1/{size}/5245.png"
          },
          {
            id: 3,
            username: "CodingHorror",
            avatar_template:
              "/user_avatar/meta.discourse.org/codinghorror/{size}/5245.png"
          }
        ],
        primary_groups: [],
        topic_list: {
          can_create_topic: true,
          draft: null,
          draft_key: "new_topic",
          draft_sequence: 0,
          per_page: 30,
          topics: [
            {
              id: 12199,
              title: "This is a private message 1",
              fancy_title: "This is a private message 1",
              slug: "this-is-a-private-message-1",
              posts_count: 0,
              reply_count: 0,
              highest_post_number: 0,
              image_url: null,
              created_at: "2018-03-16T03:38:45.583Z",
              last_posted_at: null,
              bumped: true,
              bumped_at: "2018-03-16T03:38:45.583Z",
              unseen: false,
              pinned: false,
              unpinned: null,
              visible: true,
              closed: false,
              archived: false,
              bookmarked: null,
              liked: null,
              views: 0,
              like_count: 0,
              has_summary: false,
              archetype: "private_message",
              last_poster_username: "bruce1",
              category_id: null,
              pinned_globally: false,
              featured_link: null,
              posters: [
                {
                  extras: "latest single",
                  description: "Original Poster, Most Recent Poster",
                  user_id: 2,
                  primary_group_id: null
                }
              ],
              participants: [
                {
                  extras: "latest",
                  description: null,
                  user_id: 2,
                  primary_group_id: null
                },
                {
                  extras: null,
                  description: null,
                  user_id: 3,
                  primary_group_id: null
                }
              ]
            }
          ]
        }
      });
    }
  );

  await visit("/g/discourse");
  await click(".nav-pills li a[title='Messages']");

  assert.equal(
    find(".topic-list-item .link-top-line")
      .text()
      .trim(),
    "This is a private message 1",
    "it should display the list of group topics"
  );
});

QUnit.test("Admin Viewing Group", async assert => {
  await visit("/g/discourse");

  assert.ok(
    find(".nav-pills li a[title='Manage']").length === 1,
    "it should show manage group tab if user is admin"
  );

  assert.equal(
    count(".group-message-button"),
    1,
    "it displays show group message button"
  );
  assert.equal(
    find(".group-info-name").text(),
    "Awesome Team",
    "it should display the group name"
  );
});

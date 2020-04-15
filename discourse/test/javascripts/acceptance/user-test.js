import { acceptance } from "helpers/qunit-helpers";
import pretender from "helpers/create-pretender";
import Draft from "discourse/models/draft";
import { Promise } from "rsvp";

acceptance("User", { loggedIn: true });

QUnit.test("Invalid usernames", async assert => {
  pretender.get("/u/eviltrout%2F..%2F..%2F.json", () => {
    return [400, { "Content-Type": "application/json" }, {}];
  });

  await visit("/u/eviltrout%2F..%2F..%2F/summary");

  assert.equal(currentPath(), "exception-unknown");
});

QUnit.test("Unicode usernames", async assert => {
  await visit("/u/%E3%83%A9%E3%82%A4%E3%82%AA%E3%83%B3/summary");

  assert.equal(currentPath(), "user.summary");
});

QUnit.test("Invites", async assert => {
  await visit("/u/eviltrout/invited/pending");
  assert.ok($("body.user-invites-page").length, "has the body class");
});

QUnit.test("Messages", async assert => {
  await visit("/u/eviltrout/messages");
  assert.ok($("body.user-messages-page").length, "has the body class");
});

QUnit.test("Notifications", async assert => {
  await visit("/u/eviltrout/notifications");
  assert.ok($("body.user-notifications-page").length, "has the body class");

  const $links = find(".item.notification a");

  assert.ok(
    $links[1].href.includes(
      "/u/eviltrout/notifications/likes-received?acting_username=aquaman"
    )
  );
});

QUnit.test("Root URL - Viewing Self", async assert => {
  await visit("/u/eviltrout");
  assert.ok($("body.user-activity-page").length, "has the body class");
  assert.equal(
    currentPath(),
    "user.userActivity.index",
    "it defaults to activity"
  );
  assert.ok(exists(".container.viewing-self"), "has the viewing-self class");
});

QUnit.test("Viewing Summary", async assert => {
  await visit("/u/eviltrout/summary");

  assert.ok(exists(".replies-section li a"), "replies");
  assert.ok(exists(".topics-section li a"), "topics");
  assert.ok(exists(".links-section li a"), "links");
  assert.ok(exists(".replied-section .user-info"), "liked by");
  assert.ok(exists(".liked-by-section .user-info"), "liked by");
  assert.ok(exists(".liked-section .user-info"), "liked");
  assert.ok(exists(".badges-section .badge-card"), "badges");
  assert.ok(exists(".top-categories-section .category-link"), "top categories");
});

QUnit.test("Viewing Drafts", async assert => {
  sandbox.stub(Draft, "get").returns(
    Promise.resolve({
      draft: null,
      draft_sequence: 0
    })
  );

  await visit("/u/eviltrout/activity/drafts");
  assert.ok(exists(".user-stream"), "has drafts stream");
  assert.ok(
    exists(".user-stream .user-stream-item-draft-actions"),
    "has draft action buttons"
  );

  await click(".user-stream button.resume-draft:eq(0)");
  assert.ok(
    exists(".d-editor-input"),
    "composer is visible after resuming a draft"
  );
  sandbox.restore();
});

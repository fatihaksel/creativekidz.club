import { acceptance } from "helpers/qunit-helpers";
acceptance("Topic Discovery", {
  settings: {
    show_pinned_excerpt_desktop: true
  }
});

QUnit.test("Visit Discovery Pages", async assert => {
  await visit("/");
  assert.ok($("body.navigation-topics").length, "has the default navigation");
  assert.ok(exists(".topic-list"), "The list of topics was rendered");
  assert.ok(exists(".topic-list .topic-list-item"), "has topics");

  assert.equal(
    find("a[data-user-card=eviltrout]:first img.avatar").attr("title"),
    "Evil Trout - Most Posts",
    "it shows user's full name in avatar title"
  );

  await visit("/c/bug");
  assert.ok(exists(".topic-list"), "The list of topics was rendered");
  assert.ok(exists(".topic-list .topic-list-item"), "has topics");
  assert.ok(!exists(".category-list"), "doesn't render subcategories");
  assert.ok(
    $("body.category-bug").length,
    "has a custom css class for the category id on the body"
  );

  await visit("/categories");
  assert.ok($("body.navigation-categories").length, "has the body class");
  assert.ok(
    $("body.category-bug").length === 0,
    "removes the custom category class"
  );
  assert.ok(exists(".category"), "has a list of categories");
  assert.ok(
    $("body.categories-list").length,
    "has a custom class to indicate categories"
  );

  await visit("/top");
  assert.ok(
    $("body.categories-list").length === 0,
    "removes the `categories-list` class"
  );
  assert.ok(exists(".topic-list .topic-list-item"), "has topics");

  await visit("/c/feature");
  assert.ok(exists(".topic-list"), "The list of topics was rendered");
  assert.ok(
    exists(".category-boxes"),
    "The list of subcategories were rendered with box style"
  );

  await visit("/c/dev");
  assert.ok(exists(".topic-list"), "The list of topics was rendered");
  assert.ok(
    exists(".category-boxes-with-topics"),
    "The list of subcategories were rendered with box-with-featured-topics style"
  );
  assert.ok(
    exists(".category-boxes-with-topics .featured-topics"),
    "The featured topics are there too"
  );
});

QUnit.test("Clearing state after leaving a category", async assert => {
  await visit("/c/dev");
  assert.ok(
    exists(".topic-list-item[data-topic-id=11994] .topic-excerpt"),
    "it expands pinned topics in a subcategory"
  );
  await visit("/");
  assert.ok(
    !exists(".topic-list-item[data-topic-id=11557] .topic-excerpt"),
    "it doesn't expand all pinned in the latest category"
  );
});

QUnit.test("Live update unread state", async assert => {
  await visit("/");
  assert.ok(
    exists(".topic-list-item:not(.visited) a[data-topic-id='11995']"),
    "shows the topic unread"
  );

  // Mimic a messagebus message
  window.MessageBus.callbacks.filterBy("channel", "/latest").map(c =>
    c.func({
      message_type: "read",
      topic_id: 11995,
      payload: {
        highest_post_number: 1,
        last_read_post_number: 2,
        notification_level: 1,
        topic_id: 11995
      }
    })
  );

  await visit("/"); // We're already there, but use this to wait for re-render

  assert.ok(
    exists(".topic-list-item.visited a[data-topic-id='11995']"),
    "shows the topic read"
  );
});

import selectKit from "helpers/select-kit-helper";
import { acceptance } from "helpers/qunit-helpers";

acceptance("Badges", { loggedIn: true });

QUnit.test("Visit Badge Pages", async assert => {
  await visit("/badges");

  assert.ok($("body.badges-page").length, "has body class");
  assert.ok(exists(".badge-groups .badge-card"), "has a list of badges");

  await visit("/badges/9/autobiographer");

  assert.ok(exists(".badge-card"), "has the badge in the listing");
  assert.ok(exists(".user-info"), "has the list of users with that badge");
  assert.ok(!exists(".badge-card:eq(0) script"));
});

QUnit.test("shows correct badge titles to choose from", async assert => {
  const availableBadgeTitles = selectKit(".select-kit");
  await visit("/badges/50/custombadge");
  await availableBadgeTitles.expand();
  assert.ok(availableBadgeTitles.rowByIndex(1).name() === "CustomBadge");
});

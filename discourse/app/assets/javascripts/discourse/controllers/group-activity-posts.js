import Controller, { inject as controller } from "@ember/controller";
import { observes } from "discourse-common/utils/decorators";
import { fmt } from "discourse/lib/computed";

export default Controller.extend({
  group: controller(),
  groupActivity: controller(),
  application: controller(),
  canLoadMore: true,
  loading: false,
  emptyText: fmt("type", "groups.empty.%@"),

  actions: {
    loadMore() {
      if (!this.canLoadMore) {
        return;
      }
      if (this.loading) {
        return;
      }
      this.set("loading", true);
      const posts = this.model;
      if (posts && posts.length) {
        const beforePostId = posts[posts.length - 1].get("id");
        const group = this.get("group.model");

        let categoryId = this.get("groupActivity.category_id");
        const opts = { beforePostId, type: this.type, categoryId };

        group
          .findPosts(opts)
          .then(newPosts => {
            posts.addObjects(newPosts);
            if (newPosts.length === 0) {
              this.set("canLoadMore", false);
            }
          })
          .finally(() => {
            this.set("loading", false);
          });
      }
    }
  },

  @observes("canLoadMore")
  _showFooter() {
    this.set("application.showFooter", !this.canLoadMore);
  }
});

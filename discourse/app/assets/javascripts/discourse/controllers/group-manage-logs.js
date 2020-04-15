import Controller, { inject as controller } from "@ember/controller";
import EmberObject from "@ember/object";
import discourseComputed, { observes } from "discourse-common/utils/decorators";

export default Controller.extend({
  group: controller(),
  application: controller(),
  loading: false,
  offset: 0,

  init() {
    this._super(...arguments);
    this.set("filters", EmberObject.create());
  },

  @discourseComputed(
    "filters.action",
    "filters.acting_user",
    "filters.target_user",
    "filters.subject"
  )
  filterParams(action, acting_user, target_user, subject) {
    return { action, acting_user, target_user, subject };
  },

  @observes(
    "filters.action",
    "filters.acting_user",
    "filters.target_user",
    "filters.subject"
  )
  _refreshModel() {
    this.get("group.model")
      .findLogs(0, this.filterParams)
      .then(results => {
        this.set("offset", 0);

        this.model.setProperties({
          logs: results.logs,
          all_loaded: results.all_loaded
        });
      });
  },

  @observes("model.all_loaded")
  _showFooter() {
    this.set("application.showFooter", this.get("model.all_loaded"));
  },

  reset() {
    this.setProperties({
      offset: 0,
      filters: EmberObject.create()
    });
  },

  actions: {
    loadMore() {
      if (this.get("model.all_loaded")) return;

      this.set("loading", true);

      this.get("group.model")
        .findLogs(this.offset + 1, this.filterParams)
        .then(results => {
          results.logs.forEach(result =>
            this.get("model.logs").addObject(result)
          );
          this.incrementProperty("offset");
          this.set("model.all_loaded", results.all_loaded);
        })
        .finally(() => {
          this.set("loading", false);
        });
    },

    clearFilter(key) {
      this.set(`filters.${key}`, "");
    }
  }
});

import Controller, { inject as controller } from "@ember/controller";
import { debounce } from "@ember/runloop";
import { action } from "@ember/object";
import discourseComputed from "discourse-common/utils/decorators";
import { INPUT_DELAY } from "discourse-common/config/environment";

export default Controller.extend({
  application: controller(),
  queryParams: ["order", "asc", "filter", "type"],
  order: null,
  asc: null,
  filter: "",
  type: null,
  groups: null,
  isLoading: false,

  @discourseComputed("groups.extras.type_filters")
  types(typeFilters) {
    const types = [];

    if (typeFilters) {
      typeFilters.forEach(type =>
        types.push({ id: type, name: I18n.t(`groups.index.${type}_groups`) })
      );
    }

    return types;
  },

  loadGroups(params) {
    this.set("isLoading", true);

    this.store
      .findAll("group", params)
      .then(groups => {
        this.set("groups", groups);

        if (groups.canLoadMore) {
          this.set("application.showFooter", !groups.canLoadMore);
        }
      })
      .finally(() => this.set("isLoading", false));
  },

  @action
  onFilterChanged(filter) {
    debounce(this, this._debouncedFilter, filter, INPUT_DELAY);
  },

  @action
  loadMore() {
    this.groups && this.groups.loadMore();
  },

  @action
  new() {
    this.transitionToRoute("groups.new");
  },

  _debouncedFilter(filter) {
    this.set("filter", filter);
  }
});

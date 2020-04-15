import { alias, not } from "@ember/object/computed";
import Controller, { inject as controller } from "@ember/controller";
import DiscourseURL from "discourse/lib/url";
import Category from "discourse/models/category";
import { observes } from "discourse-common/utils/decorators";

export default Controller.extend({
  discoveryTopics: controller("discovery/topics"),
  navigationCategory: controller("navigation/category"),
  application: controller(),

  loading: false,

  category: alias("navigationCategory.category"),
  noSubcategories: alias("navigationCategory.noSubcategories"),

  loadedAllItems: not("discoveryTopics.model.canLoadMore"),

  @observes("loadedAllItems")
  _showFooter: function() {
    this.set("application.showFooter", this.loadedAllItems);
  },

  showMoreUrl(period) {
    let url = "",
      category = this.category;

    if (category) {
      url = `/c/${Category.slugFor(category)}/${category.id}${
        this.noSubcategories ? "/none" : ""
      }/l`;
    }

    url += "/top/" + period;
    return url;
  },

  actions: {
    changePeriod(p) {
      DiscourseURL.routeTo(this.showMoreUrl(p));
    }
  }
});

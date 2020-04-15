import DiscourseRoute from "discourse/routes/discourse";
import Composer from "discourse/models/composer";
import showModal from "discourse/lib/show-modal";
import {
  filterQueryParams,
  findTopicList
} from "discourse/routes/build-topic-route";
import { queryParams } from "discourse/controllers/discovery-sortable";
import PermissionType from "discourse/models/permission-type";
import Category from "discourse/models/category";
import FilterModeMixin from "discourse/mixins/filter-mode";

export default DiscourseRoute.extend(FilterModeMixin, {
  navMode: "latest",

  queryParams,

  renderTemplate() {
    const controller = this.controllerFor("tags.show");
    this.render("tags.show", { controller });
  },

  model(params) {
    const tag = this.store.createRecord("tag", {
      id: Handlebars.Utils.escapeExpression(params.tag_id)
    });
    if (params.additional_tags) {
      this.set(
        "additionalTags",
        params.additional_tags.split("/").map(t => {
          return this.store.createRecord("tag", {
            id: Handlebars.Utils.escapeExpression(t)
          }).id;
        })
      );
    } else {
      this.set("additionalTags", null);
    }

    this.set("filterType", this.navMode.split("/")[0]);

    this.set("categorySlugPathWithID", params.category_slug_path_with_id);

    if (tag && tag.get("id") !== "none" && this.currentUser) {
      // If logged in, we should get the tag's user settings
      return this.store
        .find("tagNotification", tag.get("id").toLowerCase())
        .then(tn => {
          this.set("tagNotification", tn);
          return tag;
        });
    }

    return tag;
  },

  afterModel(tag, transition) {
    const controller = this.controllerFor("tags.show");
    controller.setProperties({
      loading: true,
      showInfo: false
    });

    const params = filterQueryParams(transition.to.queryParams, {});
    const category = this.categorySlugPathWithID
      ? Category.findBySlugPathWithID(this.categorySlugPathWithID)
      : null;
    const topicFilter = this.navMode;
    const tagId = tag ? tag.id.toLowerCase() : "none";
    let filter;

    if (category) {
      category.setupGroupsAndPermissions();
      this.set("category", category);
      filter = `tags/c/${Category.slugFor(category)}/${category.id}`;

      if (this.noSubcategories) {
        filter += "/none";
      }

      filter += `/${tagId}/l/${topicFilter}`;
    } else if (this.additionalTags) {
      this.set("category", null);
      filter = `tags/intersection/${tagId}/${this.additionalTags.join("/")}`;
    } else {
      this.set("category", null);
      filter = `tag/${tagId}/l/${topicFilter}`;
    }

    return findTopicList(this.store, this.topicTrackingState, filter, params, {
      cached: true
    }).then(list => {
      if (list.topic_list.tags && list.topic_list.tags.length === 1) {
        // Update name of tag (case might be different)
        tag.setProperties({
          id: list.topic_list.tags[0].name,
          staff: list.topic_list.tags[0].staff
        });
      }
      controller.setProperties({
        list,
        canCreateTopic: list.get("can_create_topic"),
        loading: false,
        canCreateTopicOnCategory:
          this.get("category.permission") === PermissionType.FULL,
        canCreateTopicOnTag: !tag.get("staff") || this.get("currentUser.staff")
      });
    });
  },

  titleToken() {
    const filterText = I18n.t(
      `filters.${this.navMode.replace("/", ".")}.title`
    );
    const controller = this.controllerFor("tags.show");

    if (controller.get("model.id")) {
      if (this.category) {
        return I18n.t("tagging.filters.with_category", {
          filter: filterText,
          tag: controller.get("model.id"),
          category: this.get("category.name")
        });
      } else {
        return I18n.t("tagging.filters.without_category", {
          filter: filterText,
          tag: controller.get("model.id")
        });
      }
    } else {
      if (this.category) {
        return I18n.t("tagging.filters.untagged_with_category", {
          filter: filterText,
          category: this.get("category.name")
        });
      } else {
        return I18n.t("tagging.filters.untagged_without_category", {
          filter: filterText
        });
      }
    }
  },

  setupController(controller, model) {
    this.controllerFor("tags.show").setProperties({
      model,
      tag: model,
      additionalTags: this.additionalTags,
      category: this.category,
      filterType: this.filterType,
      navMode: this.navMode,
      tagNotification: this.tagNotification,
      noSubcategories: this.noSubcategories
    });
    this.searchService.set("searchContext", model.get("searchContext"));
  },

  deactivate() {
    this._super(...arguments);
    this.searchService.set("searchContext", null);
  },

  actions: {
    invalidateModel() {
      this.refresh();
    },

    renameTag(tag) {
      showModal("rename-tag", { model: tag });
    },

    createTopic() {
      const controller = this.controllerFor("tags.show");

      if (controller.get("list.draft")) {
        this.openTopicDraft(controller.get("list"));
      } else {
        this.controllerFor("composer")
          .open({
            categoryId: controller.get("category.id"),
            action: Composer.CREATE_TOPIC,
            draftKey: controller.get("list.draft_key"),
            draftSequence: controller.get("list.draft_sequence")
          })
          .then(() => {
            // Pre-fill the tags input field
            if (controller.get("model.id")) {
              const composerModel = this.controllerFor("composer").get("model");

              composerModel.set(
                "tags",
                _.compact(
                  _.flatten([
                    controller.get("model.id"),
                    controller.get("additionalTags")
                  ])
                )
              );
            }
          });
      }
    },

    didTransition() {
      this.controllerFor("tags.show")._showFooter();
      return true;
    }
  }
});

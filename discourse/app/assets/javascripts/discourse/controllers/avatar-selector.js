import discourseComputed from "discourse-common/utils/decorators";
import Controller from "@ember/controller";
import ModalFunctionality from "discourse/mixins/modal-functionality";
import { ajax } from "discourse/lib/ajax";
import { allowsImages } from "discourse/lib/uploads";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { setting } from "discourse/lib/computed";

export default Controller.extend(ModalFunctionality, {
  gravatarName: setting("gravatar_name"),
  gravatarBaseUrl: setting("gravatar_base_url"),
  gravatarLoginUrl: setting("gravatar_login_url"),

  @discourseComputed(
    "selected",
    "user.system_avatar_upload_id",
    "user.gravatar_avatar_upload_id",
    "user.custom_avatar_upload_id"
  )
  selectedUploadId(selected, system, gravatar, custom) {
    switch (selected) {
      case "system":
        return system;
      case "gravatar":
        return gravatar;
      default:
        return custom;
    }
  },

  @discourseComputed(
    "selected",
    "user.system_avatar_template",
    "user.gravatar_avatar_template",
    "user.custom_avatar_template"
  )
  selectedAvatarTemplate(selected, system, gravatar, custom) {
    switch (selected) {
      case "system":
        return system;
      case "gravatar":
        return gravatar;
      default:
        return custom;
    }
  },

  @discourseComputed()
  allowAvatarUpload() {
    return (
      this.siteSettings.allow_uploaded_avatars &&
      allowsImages(this.currentUser.staff)
    );
  },

  actions: {
    uploadComplete() {
      this.set("selected", "uploaded");
    },

    refreshGravatar() {
      this.set("gravatarRefreshDisabled", true);

      return ajax(
        `/user_avatar/${this.get("user.username")}/refresh_gravatar.json`,
        { type: "POST" }
      )
        .then(result => {
          if (!result.gravatar_upload_id) {
            this.set("gravatarFailed", true);
          } else {
            this.set("gravatarFailed", false);

            this.user.setProperties({
              gravatar_avatar_upload_id: result.gravatar_upload_id,
              gravatar_avatar_template: result.gravatar_avatar_template
            });
          }
        })
        .finally(() => this.set("gravatarRefreshDisabled", false));
    },

    selectAvatar(url) {
      this.user
        .selectAvatar(url)
        .then(() => window.location.reload())
        .catch(popupAjaxError);
    },

    saveAvatarSelection() {
      const selectedUploadId = this.selectedUploadId;
      const type = this.selected;

      this.user
        .pickAvatar(selectedUploadId, type)
        .then(() => window.location.reload())
        .catch(popupAjaxError);
    }
  }
});

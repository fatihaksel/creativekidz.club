import { isEmpty } from "@ember/utils";
import { not } from "@ember/object/computed";
import Component from "@ember/component";
import discourseComputed, { observes } from "discourse-common/utils/decorators";
import Group from "discourse/models/group";
import { popupAjaxError } from "discourse/lib/ajax-error";
import discourseDebounce from "discourse/lib/debounce";
import EmberObject from "@ember/object";

export default Component.extend({
  disableSave: null,
  nameInput: null,

  didInsertElement() {
    this._super(...arguments);
    const name = this.get("model.name");

    if (name) {
      this.set("nameInput", name);
    } else {
      this.set("disableSave", true);
    }
  },

  canEdit: not("model.automatic"),

  @discourseComputed("basicNameValidation", "uniqueNameValidation")
  nameValidation(basicNameValidation, uniqueNameValidation) {
    return uniqueNameValidation ? uniqueNameValidation : basicNameValidation;
  },

  @observes("nameInput")
  _validateName() {
    name = this.nameInput;
    if (name === this.get("model.name")) return;

    if (name === undefined) {
      return this._failedInputValidation();
    }

    if (name === "") {
      this.set("uniqueNameValidation", null);
      return this._failedInputValidation(I18n.t("admin.groups.new.name.blank"));
    }

    if (name.length < this.siteSettings.min_username_length) {
      return this._failedInputValidation(
        I18n.t("admin.groups.new.name.too_short")
      );
    }

    if (name.length > this.siteSettings.max_username_length) {
      return this._failedInputValidation(
        I18n.t("admin.groups.new.name.too_long")
      );
    }

    this.checkGroupName();

    return this._failedInputValidation(
      I18n.t("admin.groups.new.name.checking")
    );
  },

  checkGroupName: discourseDebounce(function() {
    name = this.nameInput;
    if (isEmpty(name)) return;

    Group.checkName(name)
      .then(response => {
        const validationName = "uniqueNameValidation";

        if (response.available) {
          this.set(
            validationName,
            EmberObject.create({
              ok: true,
              reason: I18n.t("admin.groups.new.name.available")
            })
          );

          this.set("disableSave", false);
          this.set("model.name", this.nameInput);
        } else {
          let reason;

          if (response.errors) {
            reason = response.errors.join(" ");
          } else {
            reason = I18n.t("admin.groups.new.name.not_available");
          }

          this.set(validationName, this._failedInputValidation(reason));
        }
      })
      .catch(popupAjaxError);
  }, 500),

  _failedInputValidation(reason) {
    this.set("disableSave", true);

    const options = { failed: true };
    if (reason) options.reason = reason;
    this.set("basicNameValidation", EmberObject.create(options));
  }
});

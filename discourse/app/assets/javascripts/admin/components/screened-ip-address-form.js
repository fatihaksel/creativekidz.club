import discourseComputed from "discourse-common/utils/decorators";
import { schedule } from "@ember/runloop";
import Component from "@ember/component";
/**
  A form to create an IP address that will be blocked or whitelisted.
  Example usage:

    {{screened-ip-address-form action=(action "recordAdded")}}

  where action is a callback on the controller or route that will get called after
  the new record is successfully saved. It is called with the new ScreenedIpAddress record
  as an argument.
**/

import ScreenedIpAddress from "admin/models/screened-ip-address";
import { on } from "discourse-common/utils/decorators";

export default Component.extend({
  classNames: ["screened-ip-address-form"],
  formSubmitted: false,
  actionName: "block",

  @discourseComputed
  adminWhitelistEnabled() {
    return Discourse.SiteSettings.use_admin_ip_whitelist;
  },

  @discourseComputed("adminWhitelistEnabled")
  actionNames(adminWhitelistEnabled) {
    if (adminWhitelistEnabled) {
      return [
        { id: "block", name: I18n.t("admin.logs.screened_ips.actions.block") },
        {
          id: "do_nothing",
          name: I18n.t("admin.logs.screened_ips.actions.do_nothing")
        },
        {
          id: "allow_admin",
          name: I18n.t("admin.logs.screened_ips.actions.allow_admin")
        }
      ];
    } else {
      return [
        { id: "block", name: I18n.t("admin.logs.screened_ips.actions.block") },
        {
          id: "do_nothing",
          name: I18n.t("admin.logs.screened_ips.actions.do_nothing")
        }
      ];
    }
  },

  actions: {
    submit() {
      if (!this.formSubmitted) {
        this.set("formSubmitted", true);
        const screenedIpAddress = ScreenedIpAddress.create({
          ip_address: this.ip_address,
          action_name: this.actionName
        });
        screenedIpAddress
          .save()
          .then(result => {
            this.setProperties({ ip_address: "", formSubmitted: false });
            this.action(ScreenedIpAddress.create(result.screened_ip_address));
            schedule("afterRender", () =>
              this.element.querySelector(".ip-address-input").focus()
            );
          })
          .catch(e => {
            this.set("formSubmitted", false);
            const msg =
              e.jqXHR.responseJSON && e.jqXHR.responseJSON.errors
                ? I18n.t("generic_error_with_reason", {
                    error: e.jqXHR.responseJSON.errors.join(". ")
                  })
                : I18n.t("generic_error");
            bootbox.alert(msg, () =>
              this.element.querySelector(".ip-address-input").focus()
            );
          });
      }
    }
  },

  @on("didInsertElement")
  _init() {
    schedule("afterRender", () => {
      $(this.element.querySelector(".ip-address-input")).keydown(e => {
        if (e.keyCode === 13) {
          this.send("submit");
        }
      });
    });
  }
});

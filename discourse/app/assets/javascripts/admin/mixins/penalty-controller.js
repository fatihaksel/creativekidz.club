import ModalFunctionality from "discourse/mixins/modal-functionality";
import { popupAjaxError } from "discourse/lib/ajax-error";
import Mixin from "@ember/object/mixin";
import { next } from "@ember/runloop";
import { Promise } from "rsvp";

export default Mixin.create(ModalFunctionality, {
  reason: null,
  message: null,
  postEdit: null,
  postAction: null,
  user: null,
  postId: null,
  successCallback: null,
  confirmClose: false,

  resetModal() {
    this.setProperties({
      reason: null,
      message: null,
      loadingUser: true,
      postId: null,
      postEdit: null,
      postAction: "delete",
      before: null,
      successCallback: null,
      confirmClose: false
    });
  },

  beforeClose() {
    // prompt a confirmation if we have unsaved content
    if (
      !this.confirmClose &&
      ((this.reason && this.reason.length > 1) ||
        (this.message && this.message.length > 1))
    ) {
      this.send("hideModal");
      bootbox.confirm(I18n.t("admin.user.confirm_cancel_penalty"), result => {
        if (result) {
          next(() => {
            this.set("confirmClose", true);
            this.send("closeModal");
          });
        } else {
          next(() => this.send("reopenModal"));
        }
      });
      return false;
    }
  },

  penalize(cb) {
    let before = this.before;
    let promise = before ? before() : Promise.resolve();

    return promise
      .then(() => cb())
      .then(result => {
        this.set("confirmClose", true);
        this.send("closeModal");
        let callback = this.successCallback;
        if (callback) {
          callback(result);
        }
      })
      .catch(popupAjaxError);
  }
});

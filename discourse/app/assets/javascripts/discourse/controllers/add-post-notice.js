import discourseComputed from "discourse-common/utils/decorators";
import { isEmpty } from "@ember/utils";
import Controller from "@ember/controller";
import ModalFunctionality from "discourse/mixins/modal-functionality";
import { cookAsync } from "discourse/lib/text";

export default Controller.extend(ModalFunctionality, {
  post: null,
  resolve: null,
  reject: null,

  notice: null,
  saving: false,

  @discourseComputed("saving", "notice")
  disabled(saving, notice) {
    return saving || isEmpty(notice);
  },

  onShow() {
    this.setProperties({
      notice: "",
      saving: false
    });
  },

  onClose() {
    const reject = this.reject;
    if (reject) {
      reject();
    }
  },

  actions: {
    setNotice() {
      this.set("saving", true);

      const post = this.post;
      const resolve = this.resolve;
      const reject = this.reject;
      const notice = this.notice;

      // Let `updatePostField` handle state.
      this.setProperties({ resolve: null, reject: null });

      post
        .updatePostField("notice", notice)
        .then(() => cookAsync(notice, { features: { onebox: false } }))
        .then(cookedNotice => {
          post.setProperties({
            notice_type: "custom",
            notice_args: cookedNotice.string
          });
          resolve();
          this.send("closeModal");
        })
        .catch(() => {
          reject();
          this.send("closeModal");
        });
    }
  }
});

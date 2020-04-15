import discourseComputed from "discourse-common/utils/decorators";
import Component from "@ember/component";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import UploadMixin from "discourse/mixins/upload";
import { on } from "@ember/object/evented";

export default Component.extend(UploadMixin, {
  tagName: "span",

  @discourseComputed("uploading", "uploadProgress")
  uploadButtonText(uploading, progress) {
    return uploading
      ? I18n.t("admin.backups.upload.uploading_progress", { progress })
      : I18n.t("admin.backups.upload.label");
  },

  validateUploadedFilesOptions() {
    return { skipValidation: true };
  },

  uploadDone() {
    this.done();
  },

  calculateUploadUrl() {
    return "";
  },

  uploadOptions() {
    return {
      type: "PUT",
      dataType: "xml",
      autoUpload: false,
      multipart: false
    };
  },

  _init: on("didInsertElement", function() {
    const $upload = $(this.element);

    $upload.on("fileuploadadd", (e, data) => {
      ajax("/admin/backups/upload_url", {
        data: { filename: data.files[0].name }
      })
        .then(result => {
          data.url = result.url;
          data.submit();
        })
        .catch(popupAjaxError);
    });
  })
});

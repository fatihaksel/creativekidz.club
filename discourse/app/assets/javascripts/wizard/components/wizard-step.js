import { scheduleOnce } from "@ember/runloop";
import Component from "@ember/component";
import getUrl from "discourse-common/lib/get-url";
import discourseComputed, { observes } from "discourse-common/utils/decorators";
import { htmlSafe } from "@ember/template";

jQuery.fn.wiggle = function(times, duration) {
  if (times > 0) {
    this.animate(
      {
        marginLeft: times-- % 2 === 0 ? -15 : 15
      },
      duration,
      0,
      () => this.wiggle(times, duration)
    );
  } else {
    this.animate({ marginLeft: 0 }, duration, 0);
  }
  return this;
};

const alreadyWarned = {};

export default Component.extend({
  classNames: ["wizard-step"],
  saving: null,

  didInsertElement() {
    this._super(...arguments);
    this.autoFocus();
  },

  @discourseComputed("step.index")
  showQuitButton: index => index === 0,

  @discourseComputed("step.displayIndex", "wizard.totalSteps")
  showNextButton: (current, total) => current < total,

  @discourseComputed("step.displayIndex", "wizard.totalSteps")
  showDoneButton: (current, total) => current === total,

  @discourseComputed(
    "step.index",
    "step.displayIndex",
    "wizard.totalSteps",
    "wizard.completed"
  )
  showFinishButton: (index, displayIndex, total, completed) => {
    return index !== 0 && displayIndex !== total && completed;
  },

  @discourseComputed("step.index")
  showBackButton: index => index > 0,

  @discourseComputed("step.banner")
  bannerImage(src) {
    if (!src) {
      return;
    }
    return getUrl(`/images/wizard/${src}`);
  },

  @discourseComputed("step.id")
  bannerAndDescriptionClass(id) {
    return `wizard-banner-and-description wizard-banner-and-description-${id}`;
  },

  @observes("step.id")
  _stepChanged() {
    this.set("saving", false);
    this.autoFocus();
  },

  keyPress(key) {
    if (key.keyCode === 13) {
      if (this.showDoneButton) {
        this.send("quit");
      } else {
        this.send("nextStep");
      }
    }
  },

  @discourseComputed("step.index", "wizard.totalSteps")
  barStyle(displayIndex, totalSteps) {
    let ratio = parseFloat(displayIndex) / parseFloat(totalSteps - 1);
    if (ratio < 0) {
      ratio = 0;
    }
    if (ratio > 1) {
      ratio = 1;
    }

    return htmlSafe(`width: ${ratio * 200}px`);
  },

  autoFocus() {
    scheduleOnce("afterRender", () => {
      const $invalid = $(".wizard-field.invalid:eq(0) .wizard-focusable");

      if ($invalid.length) {
        return $invalid.focus();
      }

      $(".wizard-focusable:eq(0)").focus();
    });
  },

  animateInvalidFields() {
    scheduleOnce("afterRender", () =>
      $(".invalid input[type=text], .invalid textarea").wiggle(2, 100)
    );
  },

  advance() {
    this.set("saving", true);
    this.step
      .save()
      .then(response => this.goNext(response))
      .catch(() => this.animateInvalidFields())
      .finally(() => this.set("saving", false));
  },

  actions: {
    quit() {
      document.location = getUrl("/");
    },

    exitEarly() {
      const step = this.step;
      step.validate();

      if (step.get("valid")) {
        this.set("saving", true);

        step
          .save()
          .then(() => this.send("quit"))
          .catch(() => this.animateInvalidFields())
          .finally(() => this.set("saving", false));
      } else {
        this.animateInvalidFields();
        this.autoFocus();
      }
    },

    backStep() {
      if (this.saving) {
        return;
      }

      this.goBack();
    },

    nextStep() {
      if (this.saving) {
        return;
      }

      const step = this.step;
      const result = step.validate();

      if (result.warnings.length) {
        const unwarned = result.warnings.filter(w => !alreadyWarned[w]);
        if (unwarned.length) {
          unwarned.forEach(w => (alreadyWarned[w] = true));
          return window.swal(
            {
              customClass: "wizard-warning",
              title: "",
              text: unwarned.map(w => I18n.t(`wizard.${w}`)).join("\n"),
              type: "warning",
              showCancelButton: true,
              confirmButtonColor: "#6699ff"
            },
            confirmed => {
              if (confirmed) {
                this.advance();
              }
            }
          );
        }
      }

      if (step.get("valid")) {
        this.advance();
      } else {
        this.animateInvalidFields();
        this.autoFocus();
      }
    }
  }
});

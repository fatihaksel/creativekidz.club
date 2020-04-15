import { scheduleOnce } from "@ember/runloop";
import Component from "@ember/component";
import discourseDebounce from "discourse/lib/debounce";
import toMarkdown from "discourse/lib/to-markdown";
import { selectedText, selectedElement } from "discourse/lib/utilities";
import { INPUT_DELAY } from "discourse-common/config/environment";

function getQuoteTitle(element) {
  const titleEl = element.querySelector(".title");
  if (!titleEl) return;
  return titleEl.textContent.trim().replace(/:$/, "");
}

export default Component.extend({
  classNames: ["quote-button"],
  classNameBindings: ["visible"],
  visible: false,

  _isMouseDown: false,
  _reselected: false,

  _hideButton() {
    this.quoteState.clear();
    this.set("visible", false);
  },

  _selectionChanged() {
    const quoteState = this.quoteState;

    const selection = window.getSelection();
    if (selection.isCollapsed) {
      if (this.visible) {
        this._hideButton();
      }
      return;
    }

    // ensure we selected content inside 1 post *only*
    let firstRange, postId;
    for (let r = 0; r < selection.rangeCount; r++) {
      const range = selection.getRangeAt(r);
      const $selectionStart = $(range.startContainer);
      const $ancestor = $(range.commonAncestorContainer);

      if ($selectionStart.closest(".cooked").length === 0) {
        return;
      }

      firstRange = firstRange || range;
      postId = postId || $ancestor.closest(".boxed, .reply").data("post-id");

      if ($ancestor.closest(".contents").length === 0 || !postId) {
        if (this.visible) {
          this._hideButton();
        }
        return;
      }
    }

    const _selectedElement = selectedElement();
    const _selectedText = selectedText();

    const $selectedElement = $(_selectedElement);
    const cooked =
      $selectedElement.find(".cooked")[0] ||
      $selectedElement.closest(".cooked")[0];
    const postBody = toMarkdown(cooked.innerHTML);

    let opts = {
      full: _selectedText === postBody
    };

    for (
      let element = _selectedElement;
      element && element.tagName !== "ARTICLE";
      element = element.parentElement
    ) {
      if (element.tagName === "ASIDE" && element.classList.contains("quote")) {
        opts.username = element.dataset.username || getQuoteTitle(element);
        opts.post = element.dataset.post;
        opts.topic = element.dataset.topic;
        break;
      }
    }

    quoteState.selected(postId, _selectedText, opts);
    this.set("visible", quoteState.buffer.length > 0);

    // avoid hard loops in quote selection unconditionally
    // this can happen if you triple click text in firefox
    if (this._prevSelection === _selectedText) {
      return;
    }

    this._prevSelection = _selectedText;

    // on Desktop, shows the button at the beginning of the selection
    // on Mobile, shows the button at the end of the selection
    const isMobileDevice = this.site.isMobileDevice;
    const { isIOS, isAndroid, isSafari, isOpera, isIE11 } = this.capabilities;
    const showAtEnd = isMobileDevice || isIOS || isAndroid || isOpera;

    // Don't mess with the original range as it results in weird behaviours
    // where certain browsers will deselect the selection
    const clone = firstRange.cloneRange();

    // create a marker element containing a single invisible character
    const markerElement = document.createElement("span");
    markerElement.appendChild(document.createTextNode("\ufeff"));

    // on mobile, collapse the range at the end of the selection
    if (showAtEnd) {
      clone.collapse();
    }
    // insert the marker
    clone.insertNode(markerElement);

    // retrieve the position of the marker
    const $markerElement = $(markerElement);
    const markerOffset = $markerElement.offset();
    const parentScrollLeft = $markerElement.parent().scrollLeft();
    const $quoteButton = $(this.element);

    // remove the marker
    const parent = markerElement.parentNode;
    parent.removeChild(markerElement);
    // merge back all text nodes so they don't get messed up
    if (!isIE11) {
      // Skip this fix in IE11 - .normalize causes the selection to change
      parent.normalize();
    }

    // work around Safari that would sometimes lose the selection
    if (isSafari) {
      this._reselected = true;
      selection.removeAllRanges();
      selection.addRange(clone);
    }

    // change the position of the button
    scheduleOnce("afterRender", () => {
      let top = markerOffset.top;
      let left = markerOffset.left + Math.max(0, parentScrollLeft);

      if (showAtEnd) {
        const nearRightEdgeOfScreen =
          $(window).width() - $quoteButton.outerWidth() < left + 10;

        top = nearRightEdgeOfScreen ? top + 50 : top + 20;
        left = Math.min(
          left + 10,
          $(window).width() - $quoteButton.outerWidth() - 10
        );
      } else {
        top = top - $quoteButton.outerHeight() - 5;
      }

      $quoteButton.offset({ top, left });
    });
  },

  didInsertElement() {
    const { isWinphone, isAndroid } = this.capabilities;
    const wait = isWinphone || isAndroid ? INPUT_DELAY : 25;
    const onSelectionChanged = discourseDebounce(
      () => this._selectionChanged(),
      wait
    );

    $(document)
      .on("mousedown.quote-button", e => {
        this._prevSelection = null;
        this._isMouseDown = true;
        this._reselected = false;
        if (
          $(e.target).closest(".quote-button, .create, .share, .reply-new")
            .length === 0
        ) {
          this._hideButton();
        }
      })
      .on("mouseup.quote-button", () => {
        this._prevSelection = null;
        this._isMouseDown = false;
        onSelectionChanged();
      })
      .on("selectionchange.quote-button", () => {
        if (!this._isMouseDown && !this._reselected) {
          onSelectionChanged();
        }
      });
  },

  willDestroyElement() {
    $(document)
      .off("mousedown.quote-button")
      .off("mouseup.quote-button")
      .off("selectionchange.quote-button");
  },

  click() {
    this.attrs.selectText().then(() => this._hideButton());
    return false;
  }
});

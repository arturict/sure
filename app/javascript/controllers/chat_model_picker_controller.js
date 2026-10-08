import { Controller } from "@hotwired/stimulus";

// Applies a model chosen in the composer's UI::ModelPicker to the hidden
// ai_model field of the same form. Nothing is sent until the prompt is: the
// model rides on the message. A chat page renders the composer twice (main
// column and sidebar), and each copy has its own controller and field.
export default class extends Controller {
  static targets = ["input", "menu", "label", "button", "effort"];
  static values = { ariaLabel: String };

  select(event) {
    event.preventDefault();
    const { model, label, effort } = event.params;

    this.inputTarget.value = model;
    if (this.hasLabelTarget) this.labelTarget.textContent = label;
    if (this.hasButtonTarget && this.ariaLabelValue) {
      this.buttonTarget.setAttribute(
        "aria-label",
        this.ariaLabelValue.replace("%{model}", label),
      );
    }
    this.#markSelected(event.currentTarget);

    // The thinking-depth picker only means something for models that take it.
    if (this.hasEffortTarget) {
      this.effortTarget.classList.toggle("hidden", !effort);
    }

    this.#closeMenu();
  }

  // Moves the check mark and aria-checked to the chosen item, the same state
  // DS::MenuItem renders server-side for the initially selected one.
  #markSelected(chosen) {
    const items = this.menuTarget.querySelectorAll('[role="menuitemradio"]');
    const previous = Array.from(items).find(
      (item) => item.getAttribute("aria-checked") === "true",
    );
    if (previous === chosen) return;

    const previousGutter = previous?.querySelector('[aria-hidden="true"]');
    const chosenGutter = chosen.querySelector('[aria-hidden="true"]');
    if (previousGutter && chosenGutter) {
      chosenGutter.replaceChildren(...previousGutter.childNodes);
    }

    for (const item of items) {
      item.setAttribute("aria-checked", item === chosen ? "true" : "false");
    }
  }

  #closeMenu() {
    const menuElement = this.menuTarget.querySelector(
      '[data-controller~="DS--menu"]',
    );
    if (!menuElement) return;

    this.application
      .getControllerForElementAndIdentifier(menuElement, "DS--menu")
      ?.close();
    if (this.hasButtonTarget) this.buttonTarget.focus();
  }
}
